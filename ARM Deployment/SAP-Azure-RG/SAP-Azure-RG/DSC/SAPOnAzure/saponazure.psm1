<# 
 .Synopsis
  Update the configuration of a virtual machine to enable monitoring support for SAP.

 .Description
  Updates the configuration of a virtual machine to enable or update the support for monitoring for SAP systems that are installed on the virtual machine.
  The commandlet installs the extension that collects the performance data and makes it discoverable for the SAP system.

 .Parameter DisableWAD
  If this parameter is provided, the commandlet will not enable Windows Azure Diagnostics for this virtual machine.    

 .Example
   Update-VMConfigForSAP_GUI
#>
function Update-VMConfigForSAP_GUI
{
	param
	(
        [Switch] $DisableWAD
	)

    $mode = Select-AzureSAPMode

	Select-AzureSAPSubscription -Mode $mode

    $selectedVM = Select-AzureSAPVM -Mode $mode
    if (-not $selectedVM)
    {
        return
    }

    $accounts = @()
    $osDisk = Get-AzureSAPOsDisk -VM $selectedVM -Mode $mode
    $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink -Disk $osDisk -Mode $mode)
    $accounts += @{Name=$accountName}
    $disks = Get-AzureSAPDataDisk -VM $selectedVM -Mode $mode
    foreach ($disk in $disks)
    {
        $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink -Disk $disk -Mode $mode)
        if (-not ($accounts | where Name -eq $accountName))
        {
            $accounts += @{Name=$accountName}
        }
    }

    $wadparams = @{}
    $wadstorage = $accounts | where { (Get-StorageAccountFromCache -StorageAccountName $_.Name -Mode $mode).AccountType -like "Standard*" } | select -First 1
    if (-not $wadstorage)
    {
        do
        {
            $wadStorageName = Read-Host -Prompt ("Enter a Standard Storage Account that can be used for Diagnostics Extension")
            $wadAccount = Get-StorageAccountFromCache -StorageAccountName $wadStorageName -Mode $mode
            if ($wadAccount.AccountType -like "Standard*")
            {
                $wadparams.Add("WADStorageAccountName", $wadStorageName)
                break
            }
            else
            {
                Write-Host "ERROR: Storage Account has type"$wadAccount.AccountType". A Standard Storage Account is needed."
            }


        } while ($true)
    }	
	
	$osType = Get-AzureSAPOSType -OSDisk $osDisk -Mode $mode	
	if ([String]::IsNullOrEmpty($osType))
	{
		#TODO
	}

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        Update-VMConfigForSAP -VMName $selectedVM.Name -VMServiceName $selectedVM.ServiceName -OSType $osType -UseClassicMode @wadparams @PSBoundParameters
    }
    else
    {
        Update-VMConfigForSAP -VMName $selectedVM.Name -VMResourceGroupName $selectedVM.ResourceGroupName -OSType $osType @wadparams @PSBoundParameters
    }
}

<# 
 .Synopsis
  Update the configuration of a virtual machine to enable monitoring support for SAP.

 .Description
  Updates the configuration of a virtual machine to enable or update the support for monitoring for SAP systems that are installed on the virtual machine.
  The commandlet installs the extension that collects the performance data and makes it discoverable for the SAP system.

 .Parameter VMName
  The name of the virtual machine that should be enable for monitoring.

 .Parameter VMServiceName
  The name of the cloud service that the virtual machine is part of.

 .Parameter DisableWAD
  If this parameter is provided, the commandlet will not enable Windows Azure Diagnostics for this virtual machine.    

 .Example
   Update-VMConfigForSAP -VMName SAPVM -ServiceName SAPLandscape
#>
function Update-VMConfigForSAP
{
    param
    (
        [Parameter(Mandatory=$True)] $VMName,
        [Parameter(ParameterSetName='classic', Mandatory=$True)] $VMServiceName,
        [Parameter(ParameterSetName='arm', Mandatory=$True)] $VMResourceGroupName,
        [Switch] $DisableWAD,
        [Switch] $UseClassicMode,
        $WADStorageAccountName,
		[String] $OSType
    )

    $mode = $DEPLOY_MODE_ARM
    if ($UseClassicMode)
    {
        $mode = $DEPLOY_MODE_ASM
    }

    Write-Verbose "Retrieving VM..."

    if ($mode -eq $DEPLOY_MODE_ASM)
    {
        $selectedVM = Get-AzureVM -ServiceName $VMServiceName -Name $VMName
        $selectedRole = Get-AzureRole -ServiceName $VMServiceName -RoleName $VMName -Slot Production

        if (-not $selectedVM)
        {
            $subName = (Get-AzureSubscription -Current).SubscriptionName
            Write-Error "No VM with name $VMName and Service Name $VMServiceName in subscription $subName found"
            return
        }
        if (-not $selectedVM.VM.ProvisionGuestAgent)
        {        
            Write-Warning $missingGuestAgentWarning
            return
        }
    }
    else
    {
        $selectedVM = Get-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName
        $selectedVMStatus = Get-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status

        if (-not $selectedVM)
        {
            $subName = (Get-AzureRmContext).SubscriptionId
            Write-Error "No VM with name $VMName and Service Name $VMServiceName in subscription $subName found"
            return
        }
    }	

    $osdisk = Get-AzureSAPOSDisk -VM $selectedVM -Mode $mode

	if ([String]::IsNullOrEmpty($OSType))
	{
		$OSType = Get-AzureSAPOSType -OSDisk $osdisk -Mode $mode	
	}
	if ([String]::IsNullOrEmpty($OSType))
	{
		Write-Error "Could not determine Operating System of the VM. Please provide the Operating System type ($OS_WINDOWS or $OS_LINUX) via parameter OSType"
        return
	}

	$disks = Get-AzureSAPDataDisk -VM $selectedVM -Mode $mode
    
    $sapmonPublicConfig = @()
    $sapmonPrivateConfig = @()
    $cpuOvercommit = 0
    $memOvercommit = 0
    $vmsize = Get-AzureSAPVMInstanceSize -VM $selectedVM -Mode $mode
    switch ($vmsize)
    {
        {($_ -eq "ExtraSmall") -or ($_ -eq "Standard_A0") -or ($_ -eq "Basic_A0")}
         
        { 
            $vmsize = "ExtraSmall (A0)"
            Write-Verbose "VM Size is ExtraSmall - setting overcommitted setting"
            $cpuOvercommit = 1
        }
        "Small" { $vmsize = "Small (A1)" }
        "Medium" { $vmsize = "Medium (A2)" }
        "Large" { $vmsize = "Large (A3)" }
        "ExtraLarge" { $vmsize = "ExtraLarge (A4)" }
    }
    $sapmonPublicConfig += @{ key = "vmsize";value=$vmsize}
    $sapmonPublicConfig += @{ key = "vm.memory.isovercommitted";value=$memOvercommit}
    $sapmonPublicConfig += @{ key = "vm.cpu.isovercommitted";value=$cpuOvercommit}
    $sapmonPublicConfig += @{ key = "script.version";value=$CurrentScriptVersion}
    $sapmonPublicConfig += @{ key = "verbose";value="0"}
    $sapmonPublicConfig += @{ key = "href";value="http://aka.ms/sapaem"}

    $vmSLA = Get-VMSLA -VM $selectedVM -Mode $mode
    if ($vmSLA.HasSLA -eq $true)
    {
        $sapmonPublicConfig += @{ key = "vm.sla.throughput";value=$vmSLA.TP}
        $sapmonPublicConfig += @{ key = "vm.sla.iops";      value=$vmSLA.IOPS}
    }
    

	# Get Disks
    $accounts = @()
    $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink -Disk $osdisk -Mode $mode)
    $storageKey = (Get-AzureStorageKeyFromCache  -StorageAccountName $accountName -Mode $mode)
    $accounts += @{Name=$accountName;Key=$storageKey}

    Write-Host "[INFO] Adding configuration for OS disk"
    $caching = Get-AzureSAPDiskCaching -Disk $osdisk -Mode $mode  
    $sapmonPublicConfig += @{ key = "osdisk.name";value=(Get-DiskName -Disk $osdisk -Mode $mode)}
    $sapmonPublicConfig += @{ key = "osdisk.caching";value=$caching}
    if ((IsPremiumStorageAccount -StorageAccountName $accountName -Mode $mode) -eq $true)
    {
        Write-Verbose "[VERBOSE] OS Disk Storage Account is a premium account - adding SLAs for OS disk"
        $sapmonPublicConfig += @{ key = "osdisk.type";value=$DISK_TYPE_PREMIUM}
        $sla = Get-DiskSLA -Disk (Get-AzureSAPOSDisk -VM $selectedVM -Mode $mode) -Mode $mode
        $sapmonPublicConfig += @{ key = "osdisk.sla.throughput";value=$sla.TP}
        $sapmonPublicConfig += @{ key = "osdisk.sla.iops";value=$sla.IOPS}
                
    }
    else
    {
        $sapmonPublicConfig += @{ key = "osdisk.type";value=$DISK_TYPE_STANDARD}
        $sapmonPublicConfig += @{ key = "osdisk.connminute";value=($accountName + ".minute")}
        $sapmonPublicConfig += @{ key = "osdisk.connhour";value=($accountName + ".hour")}
    }

	# Get Storage accounts from disks
    $diskNumber = 1
    foreach ($disk in $disks)
    {
        $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink -Disk $disk -Mode $mode)
        if (-not ($accounts | where Name -eq $accountName))
        {
            $storageKey = (Get-AzureStorageKeyFromCache  -StorageAccountName $accountName -Mode $mode)
            $accounts += @{Name=$accountName;Key=$storageKey}
        }           

        $diskName = (Get-DiskName -Disk $disk -Mode $mode)
        Write-Host ("[INFO] Adding configuration for data disk " + $diskName)        
        $caching = Get-AzureSAPDiskCaching -Disk $disk -Mode $mode
        $sapmonPublicConfig += @{ key = "disk.lun.$diskNumber";value=$disk.Lun}
        $sapmonPublicConfig += @{ key = "disk.name.$diskNumber";value=$diskName}
        $sapmonPublicConfig += @{ key = "disk.caching.$diskNumber";value=$caching}

        if ((IsPremiumStorageAccount -StorageAccountName $accountName -Mode $mode) -eq $true)
        {
            Write-Verbose "[VERBOSE] Data Disk $diskNumber Storage Account is a premium account - adding SLAs for disk"
            $sapmonPublicConfig += @{ key = "disk.type.$diskNumber";value=$DISK_TYPE_PREMIUM}
            $sla = Get-DiskSLA -Disk $disk -Mode $mode
            $sapmonPublicConfig += @{ key = "disk.sla.throughput.$diskNumber";value=$sla.TP}
            $sapmonPublicConfig += @{ key = "disk.sla.iops.$diskNumber";value=$sla.IOPS}
            Write-Verbose "[VERBOSE] Done - Data Disk $diskNumber Storage Account is a premium account - adding SLAs for disk"
                
        }
        else
        {
            $sapmonPublicConfig += @{ key = "disk.type.$diskNumber";value=$DISK_TYPE_STANDARD}
            $sapmonPublicConfig += @{ key = "disk.connminute.$diskNumber";value=($accountName + ".minute")}
            $sapmonPublicConfig += @{ key = "disk.connhour.$diskNumber";value=($accountName + ".hour")}        
        }

        $diskNumber += 1
    }
    
	# Check storage accounts for analytics
    foreach ($account in $accounts)
    {
        Write-Verbose "Testing Storage Metrics for $account"

        $storageKey = $null
        $context    = $null
        $sas = $null

		$storage = Get-StorageAccountFromCache -StorageAccountName $account.Name -Mode $mode
		if ($storage.AccountType -like "Standard*")
		{
			$currentConfig = Get-StorageAnalytics -AccountName $account.Name -Mode $mode

			if (-not (Check-StorageAnalytics $currentConfig))
			{
				Write-Host "[INFO] Enabling Storage Account Metrics for storage account"$account.Name

				# Enable analytics on storage accounts
				Set-StorageAnalytics -AccountName $account.Name -StorageServiceProperties $DefaultStorageAnalyticsConfig -Mode $mode
			}            
			
			$endpoint = Get-AzureSAPTableEndpoint -StorageAccount $storage -Mode $mode
			$hourUri = "$endpoint$MetricsHourPrimaryTransactionsBlob"
			$minuteUri = "$endpoint$MetricsMinutePrimaryTransactionsBlob"

			Write-Host "[INFO] Adding Storage Account Metric information for storage account"($account.Name)
        
			$sapmonPrivateConfig += @{ key = (($account.Name) + ".hour.key");value=$account.Key}
			$sapmonPrivateConfig += @{ key = (($account.Name) + ".minute.key");value=$account.Key}
        
			$sapmonPublicConfig += @{ key = (($account.Name) + ".hour.uri");value=$hourUri}
			$sapmonPublicConfig += @{ key = (($account.Name) + ".minute.uri");value=$minuteUri}
			$sapmonPublicConfig += @{ key = (($account.Name) + ".hour.name");value=$account.Name}
			$sapmonPublicConfig += @{ key = (($account.Name) + ".minute.name");value=$account.Name}
		}
		else
		{
			Write-Host "[INFO]"($account.Name)"is of type"($storage.AccountType)"- Storage Account Metrics are not available for Premium Type Storage."
			$sapmonPublicConfig += @{ key = (($account.Name) + ".hour.ispremium");value="1"}
			$sapmonPublicConfig += @{ key = (($account.Name) + ".minute.ispremium");value="1"}
		}
    }

	# Enable VM Diagnostics
    if (-not $DisableWAD)
    {
        Write-Host ("[INFO] Enabling IaaSDiagnostics for VM " + $selectedVM.Name)

        if ([String]::IsNullOrEmpty($WADStorageAccountName))
        {
            $wadstorage = $accounts | where { (Get-StorageAccountFromCache -StorageAccountName $_.Name -Mode $mode ).AccountType -like "Standard*" } | select -First 1
        }
        else
        {
            $wadstorage = @{ Name = $WADStorageAccountName; Key = Get-AzureStorageKeyFromCache -StorageAccountName $WADStorageAccountName -Mode $mode}
        }

        if (-not $wadstorage)
        {
            Write-Error "A Standard Storage Account is required."
        }


        $selectedVM = Set-AzureVMDiagnosticsExtensionC -VM $selectedVM -StorageAccountName $wadstorage.Name -StorageAccountKey $wadstorage.Key -Mode $mode -OSType $OSType
    
        $storage = Get-StorageAccountFromCache -StorageAccountName $wadstorage.Name -Mode $mode
        $endpoint = Get-AzureSAPTableEndpoint -StorageAccount $storage -Mode $mode
        $wadUri = "$endpoint$wadTableName"

        $sapmonPrivateConfig += @{ key = "wad.key";value=$wadstorage.Key}
        $sapmonPublicConfig += @{ key = "wad.name";value=$wadstorage.Name}
        $sapmonPublicConfig += @{ key = "wad.isenabled";value="1"}
        $sapmonPublicConfig += @{ key = "wad.uri";value=$wadUri}
    }
    else
    {
        $sapmonPublicConfig += @{ key = "wad.isenabled";value="0"}
    }
    
    $jsonPublicConfig = @{}
    $jsonPublicConfig.cfg = $sapmonPublicConfig
    $publicConfString = ConvertTo-Json $jsonPublicConfig
    Write-Verbose $publicConfString
    
    $jsonPrivateConfig = @{}
    $jsonPrivateConfig.cfg = $sapmonPrivateConfig
    $privateConfString = ConvertTo-Json $jsonPrivateConfig  
    Write-Verbose $privateConfString

    Write-Host "[INFO] Updating Azure Enhanced Monitoring Extension for SAP configuration - Please wait..."
    if ($mode -eq $DEPLOY_MODE_ASM)
    {
        $selectedVM = Set-AzureVMExtension -ExtensionName $EXTENSION_AEM["$OSType$mode"].Name -Publisher $EXTENSION_AEM["$OSType$mode"].Publisher -VM $selectedVM -PrivateConfiguration $privateConfString -PublicConfiguration $publicConfString -Version $EXTENSION_AEM["$OSType$mode"].Version
        $selectedVM = Update-AzureVM -Name $selectedVM.Name -VM $selectedVM.VM -ServiceName $selectedVM.ServiceName
    }
    else
    {
        Write-Verbose "Installing AEM extension"
        $nul = Set-AzureRmVMExtension -ResourceGroupName $selectedVM.ResourceGroupName -VMName $selectedVM.Name -Name $EXTENSION_AEM["$OSType$mode"].Name -Publisher $EXTENSION_AEM["$OSType$mode"].Publisher -ExtensionType $EXTENSION_AEM["$OSType$mode"].Name -TypeHandlerVersion $EXTENSION_AEM["$OSType$mode"].Version -SettingString $publicConfString -ProtectedSettingString $privateConfString -Location $selectedVM.Location
        Write-Verbose "Setting auto upgrade for ARM extension"
        $selectedVM = Get-AzureRmVM -ResourceGroupName $selectedVM.ResourceGroupName -Name $selectedVM.Name
        ($selectedVM.Extensions | where { $_.Publisher -eq $EXTENSION_AEM["$OSType$mode"].Publisher -and $_.ExtensionType -eq $EXTENSION_AEM["$OSType$mode"].Name }).AutoUpgradeMinorVersion = $true
        
        #WA
        $selectedVM.Tags = $null
        $selectedVM = $selectedVM | Update-AzureRmVM

    }
    Write-Host "[INFO] Azure Enhanced Monitoring Extension for SAP configuration updated. It can take up to 15 Minutes for the monitoring data to appear in the SAP system."
    Write-Host "[INFO] You can check the configuration of a virtual machine by calling the Test-VMConfigForSAP_GUI commandlet."
}

<# 
 .Synopsis
  Checks the configuration of a virtual machine that should be enabled for monitoring.

 .Description  
  This commandlet will check the configuration of the extension that collects the performance data and if performance data is available. 

 .Example
  Test-VMConfigForSAP_GUI
#>
function Test-VMConfigForSAP_GUI
{
    param
    (
    )

    $mode = Select-AzureSAPMode

    Select-AzureSAPSubscription -Mode $mode

    $selectedVM = Select-AzureSAPVM -Mode $mode
    if (-not $selectedVM)
    {
        return
    }

    $osDisk = Get-AzureSAPOsDisk -VM $selectedVM -Mode $mode
    $osType = Get-AzureSAPOSType -OSDisk $osDisk -Mode $mode	
	if ([String]::IsNullOrEmpty($osType))
	{
		#TODO
	}

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        Test-VMConfigForSAP -VMName $selectedVM.Name -VMServiceName $selectedVM.ServiceName -UseClassicMode -OSType $osType
    }
    else
    {
        Test-VMConfigForSAP -VMName $selectedVM.Name -VMResourceGroupName $selectedVM.ResourceGroupName -OSType $osType
    }
}

<# 
 .Synopsis
  Checks the configuration of a virtual machine that should be enabled for monitoring.

 .Description  
  This commandlet will check the configuration of the extension that collects the performance data and if performance data is available. 
  
 .Parameter VMName
  The name of the virtual machine that should be enable for monitoring.

 .Parameter VMServiceName
  The name of the cloud service that the virtual machine is part of.

 .Parameter ContentAgeInMinutes
  Defines how old the performance data is allowed to be.

 .Example
  Test-VMConfigForSAP -VMName SAPVM -VMServiceName SAPLandscape
#>
function Test-VMConfigForSAP
{	
    param
    (
        [Parameter(Mandatory=$True)] $VMName,
        [Parameter(ParameterSetName='classic', Mandatory=$True)] $VMServiceName,
        [Parameter(ParameterSetName='arm', Mandatory=$True)] $VMResourceGroupName,
        [Switch] $UseClassicMode,
		$OSType,
        $ContentAgeInMinutes = 5
    )

    $OverallResult = $true
    

    $mode = $DEPLOY_MODE_ARM
    if ($UseClassicMode)
    {
        $mode = $DEPLOY_MODE_ASM
    }

    #################################################
    # Check if VM exists
    #################################################
    Write-Host "VM Existance check for $VMName ..." -NoNewline
    if ($mode -eq $DEPLOY_MODE_ASM)
    {
        $selectedVM = Get-AzureVM -ServiceName $VMServiceName -Name $VMName
    }
    else
    {
        $selectedVM = Get-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName
        $selectedVMStatus = Get-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status
    }

    if (-not $selectedVM)
    {
        Write-Host "NOT OK " -ForegroundColor Red        
        return
    }
    else
    {
        Write-Host "OK " -ForegroundColor Green
    }
    #################################################    
    #################################################

    $osdisk = Get-AzureSAPOSDisk -VM $selectedVM -Mode $mode

	if ([String]::IsNullOrEmpty($OSType))
	{
		$OSType = Get-AzureSAPOSType -OSDisk $osdisk -Mode $mode	
	}
	if ([String]::IsNullOrEmpty($OSType))
	{
		Write-Error "Could not determine Operating System of the VM. Please provide the Operating System type ($OS_WINDOWS or $OS_LINUX) via parameter OSType"
        return
	}

    #################################################
    # Check for Guest Agent
    #################################################
    Write-Host "VM Guest Agent check..." -NoNewline
    $vmAgentStatus = $false
    if ($mode -eq $DEPLOY_MODE_ASM)
    {
        $vmAgentStatus = $selectedVM.VM.ProvisionGuestAgent
    }
    else
    {
        # It is not possible to detect if VM Agent is installed on ARM
        $vmAgentStatus = $true
    }
    if (-not $vmAgentStatus)
    {
        Write-Host "NOT OK " -ForegroundColor Red
        Write-Warning $missingGuestAgentWarning
        return
    }
    else
    {     
	    Write-Host "OK " -ForegroundColor Green
    }
    #################################################    
    #################################################


    #################################################
    # Check for Azure Enhanced Monitoring Extension for SAP
    #################################################
    Write-Host "Azure Enhanced Monitoring Extension for SAP Installation check..." -NoNewline
    $monPublicConfig = $null
    if ($mode -eq $DEPLOY_MODE_ASM)
    {
        $extensions = @(Get-AzureVMExtension -VM $selectedVM)
        $monExtension = $extensions | where { $_.ExtensionName -eq $EXTENSION_AEM["$OSType$mode"].Name -and $_.Publisher -eq $EXTENSION_AEM["$OSType$mode"].Publisher }
        $monPublicConfig = $monExtension.PublicConfiguration
    }
    else
    {
        $extensions = @($selectedVM.Extensions)
        $monExtension = $extensions | where { $_.ExtensionType -eq $EXTENSION_AEM["$OSType$mode"].Name -and $_.Publisher -eq $EXTENSION_AEM["$OSType$mode"].Publisher }
        $monPublicConfig = $monExtension.Settings
    }

    if (-not $monExtension -or [String]::IsNullOrEmpty($monPublicConfig))
    {
        Write-Host "NOT OK " -ForegroundColor Red
        $OverallResult = $false
    }
    else
    {
	    Write-Host "OK " -ForegroundColor Green
    }
    #################################################    
    #################################################

    $accounts = @()
    $osdisk = Get-AzureSAPOSDisk -VM $selectedVM -Mode $mode
	$disks = Get-AzureSAPDataDisk -VM $selectedVM -Mode $mode
    $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink $osdisk -Mode $mode)
    $osaccountName = $accountName
    $accounts += @{Name=$accountName}
    foreach ($disk in $disks)
    {
        $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink $disk -Mode $mode)
        if (-not ($accounts | where Name -eq $accountName))
        {            
            $accounts += @{Name=$accountName}
        }
    }


    #################################################
    # Check storage metrics
    #################################################
    Write-Host "Storage Metrics check..."
    foreach ($account in $accounts)
    {
        Write-Host "`tStorage Metrics check for"$account.Name"..."
		$storage = Get-StorageAccountFromCache -StorageAccountName $account.Name -Mode $mode
		if ($storage.AccountType -like "Standard*")
		{
			Write-Host "`t`tStorage Metrics configuration check for"$account.Name"..." -NoNewline
			$currentConfig = Get-StorageAnalytics -AccountName $account.Name -Mode $mode

			if (-not (Check-StorageAnalytics $currentConfig))
			{            
				Write-Host "NOT OK " -ForegroundColor Red
				$OverallResult = $false
			}
			else
			{
				Write-Host "OK " -ForegroundColor Green
			}

			Write-Host "`t`tStorage Metrics data check for"$account.Name"..." -NoNewline
			$filterMinute =  [Microsoft.WindowsAzure.Storage.Table.TableQuery]::GenerateFilterConditionForDate("Timestamp", "gt", (get-date).AddMinutes($ContentAgeInMinutes * -1))
			if (Check-TableAndContent -StorageAccountName $account.Name -TableName $MetricsMinutePrimaryTransactionsBlob -FilterString $filterMinute -WaitChar "." -Mode $mode)
			{
				Write-Host "OK " -ForegroundColor Green
			}
			else
			{            
				Write-Host "NOT OK " -ForegroundColor Red
				$OverallResult = $false
			}
		}
		else
		{
			Write-Host "`t`tStorage Metrics not available for Premium Storage account"$account.Name"..." -NoNewline
			Write-Host "OK " -ForegroundColor Green
		}
    }
    ################################################# 
    #################################################    

    
    #################################################
    # Check Azure Enhanced Monitoring Extension for SAP Configuration
    #################################################
    Write-Host "Azure Enhanced Monitoring Extension for SAP public configuration check..." -NoNewline
    if ($monExtension)
    {        
        Write-Host "" #New Line

        $sapmonPublicConfig = ConvertFrom-Json $monPublicConfig

        $storage = Get-StorageAccountFromCache -StorageAccountName $osaccountName -Mode $mode
		$osaccountIsPremium = ($storage.AccountType -notlike "Standard*")
        $endpoint = Get-AzureSAPTableEndpoint -StorageAccount $storage -Mode $mode
        $minuteUri = "$endpoint$MetricsMinutePrimaryTransactionsBlob"

        $vmSize = Get-VMSize -VM $selectedVM -Mode $mode
        $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Size ..." -PropertyName "vmsize" -Properties $sapmonPublicConfig -ExpectedValue $vmSize
        #$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Role Name ..." -PropertyName "vm.roleinstance" -Properties $sapmonPublicConfig -ExpectedValue $selectedVM.VM.RoleName
        $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Memory ..." -PropertyName "vm.memory.isovercommitted" -Properties $sapmonPublicConfig -ExpectedValue 0
        $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM CPU ..." -PropertyName "vm.cpu.isovercommitted" -Properties $sapmonPublicConfig -ExpectedValue 0
        #$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: Deployment ID ..." -PropertyName "vm.deploymentid" -Properties $sapmonPublicConfig -ExpectedValue $selectedRole.DeploymentID
        $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: Script Version ..." -PropertyName "script.version" -Properties $sapmonPublicConfig
        
        $vmSLA = Get-VMSLA -VM $selectedVM -Mode $mode
        if ($vmSLA.HasSLA -eq $true)
        {
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM SLA IOPS ..." -PropertyName "vm.sla.iops" -Properties $sapmonPublicConfig -ExpectedValue $vmSLA.IOPS
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM SLA Throughput ..." -PropertyName "vm.sla.throughput" -Properties $sapmonPublicConfig -ExpectedValue $vmSLA.TP
            
        }

        $wadEnabled = Get-MonPropertyValue -PropertyName "wad.isenabled" -Properties $sapmonPublicConfig
        if ($wadEnabled -eq 1)
        {
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: WAD name ..." -PropertyName "wad.name" -Properties $sapmonPublicConfig
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: WAD URI ..." -PropertyName "wad.uri" -Properties $sapmonPublicConfig
        }
        else
        {
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: WAD name ..." -PropertyName "wad.name" -Properties $sapmonPublicConfig -ExpectedValue $null
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: WAD URI ..." -PropertyName "wad.uri" -Properties $sapmonPublicConfig -ExpectedValue $null
        }

		if (-not $osaccountIsPremium)
		{
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS disk URI Key ..." -PropertyName "osdisk.connminute" -Properties $sapmonPublicConfig -ExpectedValue "$osaccountName.minute"
            #TODO: check uri config
			$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS disk URI Value ..." -PropertyName "$osaccountName.minute.uri" -Properties $sapmonPublicConfig -ExpectedValue $minuteUri
			$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS disk URI Name ..." -PropertyName "$osaccountName.minute.name" -Properties $sapmonPublicConfig -ExpectedValue $osaccountName
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS Disk Type ..." -PropertyName ("osdisk.type") -Properties $sapmonPublicConfig -ExpectedValue $DISK_TYPE_STANDARD
		}
		else
		{
            $sla = Get-DiskSLA -Disk $osdisk -Mode $mode
            
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS Disk Type ..." -PropertyName ("osdisk.type") -Properties $sapmonPublicConfig -ExpectedValue $DISK_TYPE_PREMIUM
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS Disk SLA IOPS ..." -PropertyName ("osdisk.sla.throughput") -Properties $sapmonPublicConfig -ExpectedValue $sla.TP
            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS Disk SLA Throughput ..." -PropertyName ("osdisk.sla.iops") -Properties $sapmonPublicConfig -ExpectedValue $sla.IOPS
		}
        $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM OS disk name ..." -PropertyName "osdisk.name" -Properties $sapmonPublicConfig -ExpectedValue (Get-DiskName -Disk $osdisk -Mode $mode)

        
        $diskNumber = 1
        foreach ($disk in $disks)
        {
            $accountName = Get-StorageAccountFromUri (Get-AzureSAPDiskMediaLink -Disk $disk -Mode $mode)
            $storage = Get-StorageAccountFromCache -StorageAccountName $accountName -Mode $mode
			$accountIsPremium = ($storage.AccountType -notlike "Standard*")
            $endpoint = Get-AzureSAPTableEndpoint -StorageAccount $storage -Mode $mode
            $minuteUri = "$endpoint$MetricsMinutePrimaryTransactionsBlob"

            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber LUN ..." -PropertyName "disk.lun.$diskNumber" -Properties $sapmonPublicConfig -ExpectedValue $disk.Lun			
            if (-not $accountIsPremium)
			{				
                $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber URI Key ..." -PropertyName "disk.connminute.$diskNumber" -Properties $sapmonPublicConfig -ExpectedValue ($accountName + ".minute")
				$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber URI Value ..." -PropertyName ($accountName + ".minute.uri") -Properties $sapmonPublicConfig -ExpectedValue $minuteUri
				$OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber URI Name ..." -PropertyName ($accountName + ".minute.name") -Properties $sapmonPublicConfig -ExpectedValue $accountName
                $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber Type ..." -PropertyName ("disk.type.$diskNumber") -Properties $sapmonPublicConfig -ExpectedValue $DISK_TYPE_STANDARD
			}
			else
			{
                $sla = Get-DiskSLA -Disk $disk -Mode $mode

                $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber Type ..." -PropertyName ("disk.type.$diskNumber") -Properties $sapmonPublicConfig -ExpectedValue $DISK_TYPE_PREMIUM
                $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber SLA IOPS ..." -PropertyName ("disk.sla.throughput.$diskNumber") -Properties $sapmonPublicConfig -ExpectedValue $sla.TP
                $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber SLA Throughput ..." -PropertyName ("disk.sla.iops.$diskNumber") -Properties $sapmonPublicConfig -ExpectedValue $sla.IOPS
			}

            $OverallResult = Check-MonProp -CheckMessage "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disk $diskNumber name ..." -PropertyName "disk.name.$diskNumber" -Properties $sapmonPublicConfig -ExpectedValue (Get-DiskName -Disk $disk -Mode $mode)
            
            $diskNumber += 1
        }
        if ($disks.Count -eq 0)
        {
            Write-Host "`tAzure Enhanced Monitoring Extension for SAP public configuration check: VM Data Disks " -NoNewline
	        Write-Host "OK " -ForegroundColor Green
        }
    }
    else
    {
        Write-Host "NOT OK " -ForegroundColor Red
        $OverallResult = $false
    }
    ################################################# 
    #################################################    

    
    #################################################
    # Check WAD Configuration
    #################################################
    $wadEnabled = Get-MonPropertyValue -PropertyName "wad.isenabled" -Properties $sapmonPublicConfig
    if ($wadEnabled -eq 1)
    {
        $wadPublicConfig = $null
        if ($mode -eq $DEPLOY_MODE_ASM)
        {
            $extensions = @(Get-AzureVMExtension -VM $selectedVM)
            $wadExtension = $extensions | where { $_.ExtensionName -eq $EXTENSION_WAD["$OSType$mode"].Name -and $_.Publisher -eq $EXTENSION_WAD["$OSType$mode"].Publisher }
            $wadPublicConfig = $wadExtension.PublicConfiguration
        }
        else
        {
            $extensions = @($selectedVM.Extensions)
            $wadExtension = $extensions | where { $_.ExtensionType -eq $EXTENSION_WAD["$OSType$mode"].Name -and $_.Publisher -eq $EXTENSION_WAD["$OSType$mode"].Publisher }
            $wadPublicConfig = $wadExtension.Settings
        }
        
        Write-Host "IaaSDiagnostics check..." -NoNewline
        if ($wadExtension)
        {
            Write-Host "" #New Line
    
            Write-Host "`tIaaSDiagnostics configuration check..." -NoNewline

            $currentJSONConfig = ConvertFrom-Json ($wadPublicConfig)
            $base64 = $currentJSONConfig.xmlCfg
            [XML] $currentConfig = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))


            if (-not (Check-WADConfiguration -CurrentConfig $currentConfig))
            {
                Write-Host "NOT OK " -ForegroundColor Red            
                $OverallResult = $false
            }
            else
            {
	            Write-Host "OK " -ForegroundColor Green
            }

            Write-Host "`tIaaSDiagnostics performance counters check..."

            foreach ($perfCounter in $PerformanceCounters[$OSType])
            {
                Write-Host "`t`tIaaSDiagnostics performance counters"($perfCounter.counterSpecifier)"check..." -NoNewline
		        $currentCounter = $currentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.PerformanceCounterConfiguration | where counterSpecifier -eq $perfCounter.counterSpecifier
                if ($currentCounter)
                {
	                Write-Host "OK " -ForegroundColor Green                            
                }
                else
                {
                    Write-Host "NOT OK " -ForegroundColor Red            
                    $OverallResult = $false
                }
            }

            $wadstorage = Get-MonPropertyValue -PropertyName "wad.name" -Properties $sapmonPublicConfig

            Write-Host "`tIaaSDiagnostics data check..." -NoNewline            
            
            $deploymentId
            $roleName
            if ($mode -eq $DEPLOY_MODE_ASM)
            {
                $extStatus = $selectedVM.ResourceExtensionStatusList | where HandlerName -eq ($EXTENSION_AEM["$OSType$mode"].Publisher + "." + $EXTENSION_AEM["$OSType$mode"].Name)
                if ($extStatus.FormattedMessage -match "deploymentId=(\S*) roleInstance=(\S*)")
                {
                    $deploymentId = $Matches[1]
                    $roleName = $Matches[2]
                }
                else
                {
                    Write-Warning "DeploymentId and RoleInstanceName could not be parsed from extension status"
                }
            }
            else
            {                
                $selectedVMStatus = Get-AzureRmVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status
                $extStatuses = $selectedVMStatus.Extensions | where ExtensionType -eq ($EXTENSION_AEM["$OSType$mode"].Publisher + "." + $EXTENSION_AEM["$OSType$mode"].Name)
                $aemStatus = $extStatuses.Statuses | where Message -match "deploymentId=(\S*) roleInstance=(\S*)"
                if ($aemStatus)
                {
                    $deploymentId = $Matches[1]
                    $roleName = $Matches[2]
                }
                else
                {
                    Write-Warning "DeploymentId and RoleInstanceName could not be parsed from extension status"
                }
            }

            $ok = $false
            if ((-not [String]::IsNullOrEmpty($deploymentId)) -and (-not [String]::IsNullOrEmpty($roleName)) -and (-not [String]::IsNullOrEmpty($wadstorage)))
            {        
               
                if ($OSType -eq $OS_LINUX)
                {
                    #PartitionKey eq ':002Fsubscriptions:002Fe663cc2d:002D722b:002D4be1:002Db636:002Dbbd9e4c60fd9:002FresourceGroups:002Fseduschdocu:002Fproviders:002FMicrosoft:002ECompute:002FvirtualMachines:002FSAPERPDemo' and RowKey lt '2519484147601271337'
                    $resIdTemp = ""
                    foreach ($char in $selectedVM.Id.ToCharArray()) 
                    { 
                        if (-not($char -match "[a-zA-Z0-9]")) 
                        { 
                            $resIdTemp += ":00" + [Convert]::ToString([int][char]$char, 16).ToUpper()
                        } 
                        else
                        {
                            $resIdTemp += $char
                        }
                    }
                    $newFilter = "PartitionKey eq '" + $resIdTemp + "' and RowKey lt '" + ([DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.AddMinutes(-5)).Ticks + "'"
                    $ok = (Check-TableAndContent -StorageAccountName $wadstorage -TableName $wadTableName -FilterString $newFilter -UseNewTableNames -WaitChar "." -Mode $mode)
                }
                else
                {
                    $filterMinute =  "Role eq '" + $ROLECONTENT + "' and DeploymentId eq '" + $deploymentId + "' and RoleInstance eq '" + $roleName + "' and PartitionKey gt '0" + [DateTime]::UtcNow.AddMinutes($ContentAgeInMinutes * -1).Ticks + "'"
                    $ok = (Check-TableAndContent -StorageAccountName $wadstorage -TableName $wadTableName -FilterString $filterMinute -WaitChar "." -Mode $mode)
                }
                
	            
            }
            if ($ok)
            {
                Write-Host "OK " -ForegroundColor Green
            }
            else
            {
                Write-Host "NOT OK " -ForegroundColor Red            
                $OverallResult = $false
            }
        }
        else
        {
            Write-Host "NOT OK " -ForegroundColor Red
            $OverallResult = $false
        }
    }
    ################################################# 
    #################################################

    if ($OverallResult -eq $false)
    {
        Write-Host "The script found some configuration issues. Please run the Update-VMConfigForSAP_GUI commandlet to update the configuration of the virtual machine!"
    }
}

function Enable-ProvisionGuestAgent_GUI
{
    param
    (
    )
    $mode = Select-AzureSAPMode

	if ($mode -eq $DEPLOY_MODE_ASM)
    {
		Select-AzureSAPSubscription -Mode $mode

		$selectedVM = Select-AzureSAPVM -Mode $mode
		if (-not $selectedVM)
		{
			return
		}

		Enable-ProvisionGuestAgent -VMName $selectedVM.Name -VMServiceName $selectedVM.ServiceName
	}
	else
	{
		Write-Host "Enabling of the VM Agent is not needed for virtual machines deployed on Azure Resource Manager"
	}
}

function Enable-ProvisionGuestAgent
{
    param
    (
        [Parameter(Mandatory=$True)] $VMName,
        [Parameter(Mandatory=$True)] $VMServiceName
    )
	
    $selectedVM = Get-AzureVM -ServiceName $VMServiceName -Name $VMName

    if (-not $selectedVM)
    {
        $subName = (Get-AzureSubscription -Current).SubscriptionName
        Write-Error "No VM with name $VMName and Service Name $VMServiceName in subscription $subName found"
        return
    }
    if ($selectedVM.VM.ProvisionGuestAgent -eq $true)
    {       
        Write-Host "Guest Agent is already installed and enabled." -ForegroundColor Green
        return
    }

    Write-Host "This commandlet will enabled the Guest Agent on the Azure Virtual Machine. The Guest Agent needs to be installed on the Azure Virtual Machine. It will not be installed as part of this commandlet. Please read the documentation for more information"

    $selectedVM.VM.ProvisionGuestAgent = $TRUE
    Update-AzureVM –Name $VMName -VM $selectedVM.VM -ServiceName $VMServiceName
}


#######################################################################
## PRIVATE METHODS
#######################################################################

function Get-DiskName
{
    param
    (
        [Parameter(Mandatory=$True)] $Disk,
        [Parameter(Mandatory=$True)] $Mode
    )

    $link = (Get-AzureSAPDiskMediaLink -Disk $Disk -Mode $Mode)
    $fileName = $link.Segments[$link.Segments.Count - 1]
    $fileName = [Uri]::UnescapeDataString($fileName)

    return $fileName
}

function Get-VMSLA
{
    param
    (
        [Parameter(Mandatory=$True)] $VM,
        [Parameter(Mandatory=$True)] $Mode
    )

    $result = @{}
    $result.HasSLA = $false
    switch (Get-AzureSAPVMInstanceSize -VM $VM -Mode $Mode)
    {        
        "Standard_DS1"  { $result.HasSLA = $true; $result.IOPS =  3200; $result.TP =   32 }
        "Standard_DS2"  { $result.HasSLA = $true; $result.IOPS =  6400; $result.TP =   64 }
        "Standard_DS3"  { $result.HasSLA = $true; $result.IOPS = 12800; $result.TP =  128 }
        "Standard_DS4"  { $result.HasSLA = $true; $result.IOPS = 25600; $result.TP =  256 }
        "Standard_DS11" { $result.HasSLA = $true; $result.IOPS =  6400; $result.TP =   64 }
        "Standard_DS12" { $result.HasSLA = $true; $result.IOPS = 12800; $result.TP =  128 }
        "Standard_DS13" { $result.HasSLA = $true; $result.IOPS = 25600; $result.TP =  256 }
        "Standard_DS14" { $result.HasSLA = $true; $result.IOPS = 50000; $result.TP =  512 }
        "Standard_GS1"  { $result.HasSLA = $true; $result.IOPS =  5000; $result.TP =  125 }
        "Standard_GS2"  { $result.HasSLA = $true; $result.IOPS = 10000; $result.TP =  250 }
        "Standard_GS3"  { $result.HasSLA = $true; $result.IOPS = 20000; $result.TP =  500 }
        "Standard_GS4"  { $result.HasSLA = $true; $result.IOPS = 40000; $result.TP = 1000 }
        "Standard_GS5"  { $result.HasSLA = $true; $result.IOPS = 80000; $result.TP = 2000 }
    }

    return $result
}

$StorageAccountKeyCache = @{}
function Get-AzureStorageKeyFromCache
{
    param
    (
        [Parameter(Mandatory=$True)] $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($StorageAccountKeyCache.ContainsKey($StorageAccountName))
    {
        return $StorageAccountKeyCache[$StorageAccountName]
    }

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        $keys = (Get-AzureStorageKey -StorageAccountName $StorageAccountName).Primary
    }
    else
    {
        $keys = (Get-AzureRmStorageAccount | where StorageAccountName -eq $StorageAccountName | Get-AzureRmStorageAccountKey).Key1
    }
    $StorageAccountKeyCache.Add($StorageAccountName, $keys)

    return $keys
}

$StorageAccountCache = @{}
function Get-StorageAccountFromCache
{
    param
    (
        [Parameter(Mandatory=$True)] $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($StorageAccountCache.ContainsKey($StorageAccountName))
    {
        Write-Verbose "Returning storage account $StorageAccountName from cache"
        return $StorageAccountCache[$StorageAccountName]
    }

    Write-Verbose "Storage account $StorageAccountName not found in cache"
    $account = Get-AzureStorageAccountWA -StorageAccountName $StorageAccountName -Mode $Mode
    Write-Verbose ("Adding Storage account $StorageAccountName to cache: name " + $account.StorageAccountName)
    $StorageAccountCache.Add($StorageAccountName, $account)

    return $account
}

function Get-DiskSLA
{
    param
    (
        [Parameter(Mandatory=$True)] $Disk,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Disk.LogicalDiskSizeInGB)
    {
        $diskSize = $Disk.LogicalDiskSizeInGB
    }
    elseif ($Disk.DiskSizeGB)
    {
        $diskSize = $Disk.DiskSizeGB
    }
    else
    { 
        $diskSize = Get-DiskSizeGB -blobUri (Get-AzureSAPDiskMediaLink $Disk -Mode $Mode).ToString() -Mode $Mode
    }
   

    $sla = @{}
    if ($diskSize -lt 129)
    {
        # P10
        $sla.IOPS = 500
        $sla.TP = 100
    }
    elseif ($diskSize -lt 513)
    {
        # P20
        $sla.IOPS = 2300
        $sla.TP = 150
    }
    elseif ($diskSize -lt 1025)
    {
        # P30
        $sla.IOPS = 5000
        $sla.TP = 200
    }
    else
    {
        Write-Error "Unkown disk size for Premium Storage - $diskSize"
        return
    }

    return $sla
}

function Get-DiskSizeGB
{
    param
    (
        $blobUri,
        [Parameter(Mandatory=$True)] $Mode
    )

    if (-not ($blobUri -match "https?://(\S*?)\..*?/(.*)"))
    {
        Write-Error "Blob URI of disk does not match known pattern ($blobUri)"
        return
    }

    $accountName = $Matches[1]
    $opsString = $Matches[2]


    $request = Create-StorageAccountRequest -accountName $accountName -resourceType "blob.core" `
            -operationString $opsString `
            -resourceString "/$accountName/$opsString" `
            -xmsversion "2014-02-14" -contentLength "" -restMethod "HEAD" -Mode $Mode

    $sizeGB = 0
    try
    {
        Write-Verbose "[VERBOSE] Requesting blob properties for $blobUri"
        $response = $request.GetResponse()
        $sizeGB = $response.Headers["Content-Length"]/(1024*1024*1024)

        $response.Close()
    }
    catch [System.Net.WebException]
    {        
        if ($_.Exception.Response)
        {
            $data = $_.Exception.Response.GetResponseStream()
            $reader = new-object System.IO.StreamReader($data)
            $text = $reader.ReadToEnd();
            Write-Verbose "Error text: $text"
        }
        throw $_.Exception.ToString()
    }

    Write-Verbose "[VERBOSE] Blob size of $blobUri is $sizeGB"
    return $sizeGB

}

function IsPremiumStorageAccount 
{
    param
    (
        $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
    )

    $account = Get-StorageAccountFromCache -StorageAccountName $StorageAccountName -Mode $Mode
    return ($account.AccountType -like "Premium*")
}

###
# Workaround for warnings: WARNING: GeoReplicationEnabled property will be deprecated in a future release of Azure PowerShell. The value will be merged into the AccountType property.
###
function Get-AzureStorageAccountWA
{
	param
	(
		[Parameter(Mandatory=$True)] $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
	)
	
    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        $OldPreference = $WarningPreference
    	$WarningPreference = "SilentlyContinue"
	    $stAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccountName
	    $WarningPreference = $OldPreference
        return $stAccount
    }
    else
    {   
        $stAccount = Get-AzureRmStorageAccount | where StorageAccountName -eq $StorageAccountName
        if (-not $stAccount)
        {
            Write-Error "Storage Account $StorageAccountName not found"
        }
        return $stAccount        
    }
}

function Get-VMSize
{
    param
    (
        [Parameter(Mandatory=$True)] $VM,
        [Parameter(Mandatory=$True)] $Mode
    )

    $vmsize = Get-AzureSAPVMInstanceSize -VM $VM -Mode $Mode
    switch ($vmsize)
    {
        "ExtraSmall" { $vmsize = "ExtraSmall (A0)" }
        "Small" { $vmsize = "Small (A1)" }
        "Medium" { $vmsize = "Medium (A2)" }
        "Large" { $vmsize = "Large (A3)" }
        "ExtraLarge" { $vmsize = "ExtraLarge (A4)" }
    }

    return $vmsize
}

function Get-MonPropertyValue
{
    param
    (
        $PropertyName,
        $Properties
    )

    $property = $Properties.cfg | where key -eq $PropertyName          
    return $property.value
}

function Check-MonProp
{
    param
    (
        $CheckMessage,
        $PropertyName,
        $Properties,
        $ExpectedValue
    )

    $value = Get-MonPropertyValue -PropertyName $PropertyName -Properties $Properties
    Write-Host $CheckMessage -NoNewline
    if ((-not [String]::IsNullOrEmpty($value) -and [String]::IsNullOrEmpty($ExpectedValue)) -or ($value -eq $ExpectedValue))
    {
        Write-Host "OK " -ForegroundColor Green
        return $true
    }
    else
    {
        Write-Host "NOT OK " -ForegroundColor Red
        return $false
    }
}

function Check-StorageAnalytics
{
    param
    (
        [XML] $CurrentConfig
    )    

    if (    (-not $CurrentConfig) `
        -or (-not $CurrentConfig.StorageServiceProperties) `
        -or (-not $CurrentConfig.StorageServiceProperties.Logging) `
        -or (-not [bool]::Parse($CurrentConfig.StorageServiceProperties.Logging.Read)) `
        -or (-not [bool]::Parse($CurrentConfig.StorageServiceProperties.Logging.Write)) `
        -or (-not [bool]::Parse($CurrentConfig.StorageServiceProperties.Logging.Delete)) `
        -or (-not $CurrentConfig.StorageServiceProperties.MinuteMetrics) `
        -or (-not [bool]::Parse($CurrentConfig.StorageServiceProperties.MinuteMetrics.Enabled)) `
        -or (-not $CurrentConfig.StorageServiceProperties.MinuteMetrics.RetentionPolicy) `
        -or (-not [bool]::Parse($CurrentConfig.StorageServiceProperties.MinuteMetrics.RetentionPolicy.Enabled)) `
        -or (-not $CurrentConfig.StorageServiceProperties.MinuteMetrics.RetentionPolicy.Days) `
        -or ([int]::Parse($CurrentConfig.StorageServiceProperties.MinuteMetrics.RetentionPolicy.Days) -lt 0))
        
    {
        return $false
    }

    return $true
}

function Check-TableAndContent
{
    param
    (
        $StorageAccountName,
        $TableName,
        $FilterString,       
        $TimeoutinMinutes = 5,
        $WaitChar,
        [Parameter(Mandatory=$True)] $Mode,
        [Switch] $UseNewTableNames
    )

    $tableExists = $false

    $account = $null
    if (-not [String]::IsNullOrEmpty($StorageAccountName))
    {
        $account = Get-StorageAccountFromCache $StorageAccountName -ErrorAction Ignore -Mode $Mode
    }
    if ($account)
    {
        $endpoint = Get-CoreEndpoint -StorageAccountName $StorageAccountName -Mode $Mode
        $keys = Get-AzureStorageKeyFromCache -StorageAccountName $StorageAccountName -Mode $Mode
        $context = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $keys -Endpoint $endpoint

        $checkStart = Get-Date
        $wait = $true
        $table = $null
        if ($UseNewTableNames)
        {
            try { $table = @(Get-AzureStorageTable -Context $context -ErrorAction SilentlyContinue | where Name -like "WADMetricsPT1M*") | select -First 1 } catch {} #table name should be sorted 
        }
        else
        {
            try { $table = Get-AzureStorageTable -Name $TableName -Context $context -ErrorAction SilentlyContinue } catch {}
        }

        while ($wait)
        {
            if ($table)
            {                    
                $query = new-object Microsoft.WindowsAzure.Storage.Table.TableQuery                
                $query.FilterString =  $FilterString
                $results = @($table.CloudTable.ExecuteQuery($query))
                
                if ($results.Count -gt 0)
                {            
                    $tableExists = $true
                    break                
                }
            }

            Write-Host $WaitChar -NoNewline
            sleep 5
            if ($UseNewTableNames)
            {
                try { $table = @(Get-AzureStorageTable -Context $context -ErrorAction SilentlyContinue | where Name -like "WADMetricsPT1M*") | select -First 1 } catch {} #table name should be sorted 
            }
            else
            {
                try { $table = Get-AzureStorageTable -Name $TableName -Context $context -ErrorAction SilentlyContinue } catch {}
            }

            $wait = ((Get-Date) - $checkStart).TotalMinutes -lt $TimeoutinMinutes
        }
    }
    return $tableExists
}


function Get-StorageAccountFromUri
{
    param
    (
        $URI
    )

    Write-Verbose "Get-StorageAccountFromUri with $URI"
    if ($URI.Host -match "(.*?)\..*")
    {
        return $Matches[1]        
    }
    else
    {
        Write-Error "Could not determine storage account for OS disk. Please contact support"
        return
    }
}

function Check-WADConfiguration
{
    param
    (
        [XML] $CurrentConfig
    )

    if ( `
            (-not $CurrentConfig) `
            -or (-not $CurrentConfig.WadCfg) `
            -or (-not $CurrentConfig.WadCfg.DiagnosticMonitorConfiguration) `
            -or ([int]::Parse($CurrentConfig.WadCfg.DiagnosticMonitorConfiguration.Attributes["overallQuotaInMB"].Value) -lt 4096) `
            -or (-not $CurrentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters) `
            -or ($CurrentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.Attributes["scheduledTransferPeriod"].Value -ne "PT1M") `
            -or (-not $CurrentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.PerformanceCounterConfiguration) `
            )
    {
        return $false      
    }

    return $true
}

function Set-AzureVMDiagnosticsExtensionC
{
    param
    (
        $VM,
        $StorageAccountName,
        $StorageAccountKey,
        [Parameter(Mandatory=$True)] $Mode,
		[Parameter(Mandatory=$True)] $OSType
    )   

    $sWADPublicConfig = [String]::Empty
    $sWADPrivateConfig = [String]::Empty
    
    $extensionName = $EXTENSION_WAD["$OSType$mode"].Name
    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        $publicConf = (Get-AzureVMExtension -ExtensionName $EXTENSION_WAD["$OSType$mode"].Name -Publisher $EXTENSION_WAD["$OSType$mode"].Publisher -VM $VM -WarningAction SilentlyContinue).PublicConfiguration    
    }
    else
    {
        $extTemp = ($VM.Extensions | where { $_.Publisher -eq $EXTENSION_WAD["$OSType$mode"].Publisher -and $_.ExtensionType -eq $EXTENSION_WAD["$OSType$mode"].Name })
        $publicConf = $extTemp.PublicConfiguration
        if ($extTemp)
        {
            $extensionName = $extTemp.Name
        }
    }

    if (-not [String]::IsNullOrEmpty($publicConf))
    {
        $currentJSONConfig = ConvertFrom-Json ($publicConf)
        $base64 = $currentJSONConfig.xmlCfg
        [XML] $currentConfig = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
    }
    $xmlnsConfig = "http://schemas.microsoft.com/ServiceHosting/2010/10/DiagnosticsConfiguration"

    if ($currentConfig.WadCfg.DiagnosticMonitorConfiguration.DiagnosticInfrastructureLogs -and 
        $currentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters)
    {
        $currentConfig.WadCfg.DiagnosticMonitorConfiguration.overallQuotaInMB = "4096"
        $currentConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.scheduledTransferPeriod = "PT1M"           

        $publicConfig = $currentConfig

    }
    else
    {    
        $publicConfig = $WADPublicConfig
    }
    $publicConfig = $WADPublicConfig
        
    foreach ($perfCounter in $PerformanceCounters[$OSType])
    {
		$currentCounter = $publicConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.PerformanceCounterConfiguration | where counterSpecifier -eq $perfCounter.counterSpecifier
        if (-not $currentCounter)
        {
            $node = $publicConfig.CreateElement("PerformanceCounterConfiguration", $xmlnsConfig)
            $nul = $publicConfig.WadCfg.DiagnosticMonitorConfiguration.PerformanceCounters.AppendChild($node)    
            $node.SetAttribute("counterSpecifier", $perfCounter.counterSpecifier)
            $node.SetAttribute("sampleRate", $perfCounter.sampleRate)
        }
    }
    
    $Endpoint = Get-CoreEndpoint $StorageAccountName -Mode $Mode
    $Endpoint = "https://$Endpoint"

    $jPublicConfig = @{}
    $jPublicConfig.xmlCfg = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicConfig.InnerXml))
    
    $jPrivateConfig = @{}    
    $jPrivateConfig.storageAccountName = $StorageAccountName
    $jPrivateConfig.storageAccountKey = $StorageAccountKey
    $jPrivateConfig.storageAccountEndPoint = $Endpoint

    $sWADPublicConfig = ConvertTo-Json $jPublicConfig
    $sWADPrivateConfig = ConvertTo-Json $jPrivateConfig
    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        $VM = Set-AzureVMExtension -ExtensionName $EXTENSION_WAD["$OSType$mode"].Name -Publisher $EXTENSION_WAD["$OSType$mode"].Publisher -PublicConfiguration $sWADPublicConfig -VM $VM -PrivateConfiguration $sWADPrivateConfig -Version $EXTENSION_WAD["$OSType$mode"].Version
    }
    else
    {
        Write-Verbose "Installing WAD extension"
        $nul = Set-AzureRmVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $extensionName -Publisher $EXTENSION_WAD["$OSType$mode"].Publisher -ExtensionType $EXTENSION_WAD["$OSType$mode"].Name -TypeHandlerVersion $EXTENSION_WAD["$OSType$mode"].Version -SettingString $sWADPublicConfig -ProtectedSettingString $sWADPrivateConfig -Location $VM.Location
        Write-Verbose "Setting auto upgrade for WAD extension"
        $VM = Get-AzureRmVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
        ($VM.Extensions | where { $_.Publisher -eq $EXTENSION_WAD["$OSType$mode"].Publisher -and $_.ExtensionType -eq $EXTENSION_WAD["$OSType$mode"].Name }).AutoUpgradeMinorVersion = $true
        
        #WA
        $VM.Tags = $null
        $nul = $VM | Update-AzureRmVM
    }
    return $VM
}

function Select-AzureSAPMode
{
    write-host "Please select the deployment mode that you used to deploy the virtual machine:"
    
	write-host ("[1] Classic (Azure Service Management)")
    write-host ("[2] Resource Manager (Azure Resource Manager)")

	$selectedMode = $null
	while (-not $selectedMode)
	{
		[int] $index = Read-Host -Prompt ("Select deployment mode [1-2]")
        if ($index -eq 1)
        {
            $selectedMode = $DEPLOY_MODE_ASM
        }
        elseif ($index -eq 2)
        {
            $selectedMode = $DEPLOY_MODE_ARM
        }
	}

    return $selectedMode
}

function Select-AzureSAPSubscription
{
    param
    (
        [Parameter(Mandatory=$True)] $Mode
    )

    $selectedEnv = $null
    $envs = @(Get-AzureSAPEnvironment -Mode $Mode)
    if ($envs.Count -gt 1)
    {
        write-host "Please select one of the following environments. Make sure to select the correct environment, especially if you want to use Microsoft Azure in China."
        $currentEnvIndex = 1
	    foreach ($currentEnv in $envs)
	    {
		    write-host ("[$currentEnvIndex] " + (Get-AzureSAPEnvironmentName -Environment $currentEnv -Mode $Mode))
		    $currentEnvIndex += 1
	    }

	    $selectedEnv = $null
	    while (-not $selectedEnv)
	    {
		    [int] $index = Read-Host -Prompt ("Select Environment [1-" + $envs.Count + "]")
		    if (($index -ge 1) -and ($index -le $envs.Count))
		    {
			    $selectedEnv = $envs[$index - 1]
		    }
	    }
    }
    elseif ($envs.Count -eq 1)
    {
        $selectedEnv = $envs[1]
    }

    if ($selectedEnv)
    {    
	    $nul = Add-AzureSAPAccount -Environment (Get-AzureSAPEnvironment -Environment $selectedEnv -Mode $Mode) -Mode $Mode
    }
    else
    {
        $nul = Add-AzureSAPAccount -Mode $Mode
    }
    
	# Select subscription
	$subscriptions = Get-AzureSAPSubscription -Mode $Mode
    if ($subscriptions.Length -gt 1)
    {
	    $currentIndex = 1
	    foreach ($currentSub in $subscriptions)
	    {
		    write-host ("[$currentIndex] " + $currentSub.SubscriptionName)
		    $currentIndex += 1
	    }

	    $selectedSubscription = $null
	    while (-not $selectedSubscription)
	    {
		    [int] $index = Read-Host -Prompt ("Select Subscription [1-" + $subscriptions.Count + "]")
		    if (($index -ge 1) -and ($index -le $subscriptions.Count))
		    {
			    $selectedSubscription = $subscriptions[$index - 1]
		    }
	    }
    }
    elseif ($subscriptions.Length -eq 1)
    {
        $selectedSubscription = $subscriptions[0]
    }

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
	    $nul = $selectedSubscription | Select-AzureSubscription
    }
    else
    {
        $nul = $selectedSubscription | Select-AzureRmSubscription
    }
}

function Get-AzureSAPEnvironment 
{
    param
    (
        $Environment,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        if ($Environment)
        {
            return Get-AzureEnvironment $Environment
        }
        else
        {
            return Get-AzureEnvironment
        }
	    
    }
    else
    {
        if ($Environment)
        {
            return Get-AzureRmEnvironment $Environment
        }
        else
        {
            return Get-AzureRmEnvironment
        }        
    }
}

function Get-AzureSAPEnvironmentName
{
    param
    (
        [Parameter(Mandatory=$True)] $Environment,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        if ($Environment | Get-Member -Name EnvironmentName) 
        {
            return $Environment.EnvironmentName
        }
        else
        {
            return $Environment.Name
        }
    }
    else
    {        
        return $Environment.Name
    }
}

function Get-AzureSAPSubscription
{
    param
    (
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        return Get-AzureSubscription
    }
    else
    {        
        return Get-AzureRmSubscription
    }
}

function Add-AzureSAPAccount
{
    param
    (
        $Environment,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        if ($Environment)
        {
            Add-AzureAccount -Environment $Environment
        }
        else
        {
            Add-AzureAccount
        }
    }
    else
    {    
    #TODO remove
        $context = $null
        try 
        {
            Write-Host "Trying to get Azure RM context"
            $context = Get-AzureRmContext -ErrorAction SilentlyContinue
            Write-Host ("Trying to get Azure RM context - done " + $context.Tenant)
        }
        catch{}

        if ((-not $context) -or (-not $context.Tenant))
        {
            if ($Environment)
            {
                Login-AzureRmAccount -Environment $Environment
            }
            else
            {
                Login-AzureRmAccount
            }
        }
    }
}


function Select-AzureSAPVM
{
    param
    (
        [Parameter(Mandatory=$True)] $Mode
    )

    # Select VM
    $selectedVM = $null
    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        $vmFilterName = Read-Host -Prompt "Please enter the name of the VM or a filter you want to use to select the VM"

        Write-Host "`tRetrieving information about virtual machines in your subscription. Please wait..."
	    $vms = Get-AzureVM | where Name -like ("*$vmFilterName*")
    }
    else
    {
        $resourceGroupName = Read-Host -Prompt "Please enter the name of the resource group that contains the virtual machine you want to configure"

        Write-Host "`tRetrieving information about virtual machines in your subscription. Please wait..."
	    $vms = Get-AzureRmVM -ResourceGroupName $resourceGroupName
    }
    
    if ($vms.Count -gt 0)
    {
	    $currentIndex = 1
	    foreach ($currentVM in $vms)
	    {
            if ($Mode -eq $DEPLOY_MODE_ASM)
            {
		        write-host ("[$currentIndex] " + $currentVM.Name + " (part of cloud service " + $currentVM.ServiceName + ")")
            }
            else
            {
                write-host ("[$currentIndex] " + $currentVM.Name + " (part of resource group " + $currentVM.ResourceGroupName + ")")
            }
		    $currentIndex += 1
	    }

	    $selectedVM = $null
	    while (-not $selectedVM)
	    {
		    [int] $index = Read-Host -Prompt ("Select Virtual Machine [1-" + $vms.Count + "]")
		    if (($index -ge 1) -and ($index -le $vms.Count))
		    {
			    $selectedVM = $vms[$index - 1]
		    }
	    }
    }        
    else
    {
        Write-Warning "No Virtual machine found that matches $vmFilterName"
        return $null
    }

    return $selectedVM
}

function Get-AzureSAPDiskMediaLink
{
    param
    (
        [Parameter(Mandatory=$True)] $Disk,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
		return $Disk.MediaLink
    }
    else
    {
        $result = [Uri] $Disk.VirtualHardDisk.Uri
        if ([String]::IsNullOrEmpty($result))
        {
            $result = [Uri] $Disk.Vhd.Uri
        }
        return $result
    }
}

function Get-AzureSAPVMInstanceSize
{
    param
    (
        [Parameter(Mandatory=$True)] $VM,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
		return $VM.InstanceSize
    }
    else
    {
        return $VM.HardwareProfile.VirtualMachineSize
    }
}

function Get-AzureSAPDataDisk
{
    param
    (
        [Parameter(Mandatory=$True)] $VM,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
		return (Get-AzureDataDisk -VM $VM)
    }
    else
    {
        return $VM.StorageProfile.DataDisks
    }

}

function Get-AzureSAPOSDisk
{
    param
    (
        [Parameter(Mandatory=$True)] $VM,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        Write-Verbose "Getting disk ASM Mode"
		return (Get-AzureOSDisk -VM $VM)
    }
    else
    {
        Write-Verbose "Getting disk ARM Mode"
        return $VM.StorageProfile.OSDisk
    }
}

function Get-AzureSAPDiskCaching
{
    param
    (
        [Parameter(Mandatory=$True)] $Disk, 
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
		return $Disk.HostCaching
    }
    else
    {
        return $Disk.Caching
    }

 }

function Get-AzureSAPTableEndpoint
{
    param
    (
        [Parameter(Mandatory=$True)] $StorageAccount,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        return ($StorageAccount.Endpoints | where { $_ -like "*table*" })
    }
    else
    {
        return ($StorageAccount.PrimaryEndpoints.Table)
    }
}

function Get-AzureSAPBlobEndpoint
{
    param
    (
        [Parameter(Mandatory=$True)] $StorageAccount,
        [Parameter(Mandatory=$True)] $Mode
    )

    if ($Mode -eq $DEPLOY_MODE_ASM)
    {
        return ($StorageAccount.Endpoints | where { $_ -like "*blob*" })
    }
    else
    {
        return ($StorageAccount.PrimaryEndpoints.Blob)
    }
}

function Get-AzureSAPOSType
{
	param
	(
		[Parameter(Mandatory=$True)] $OSDisk,
		[Parameter(Mandatory=$True)] $Mode
	)
    Write-Verbose "Getting OS Type from disk"
    
	$osType = ""
	if ($Mode -eq $DEPLOY_MODE_ASM)
    {
		$osType = $OSDisk.OS		
    }
    else
    {
        $osType = $OSDisk.OperatingSystemType
        if ([String]::IsNullOrEmpty($osType))
        {
            $osType = $OSDisk.OsType   
        }
    }

    Write-Verbose "OS Type from disk is $osType"
	if ($osType -like "Windows")
	{
		$osType = $OS_WINDOWS
	}
	elseif ($osType -like "Linux")
	{
		$osType = $OS_LINUX
	}
	else
	{
		$osType = $null
	}

	return $osType
}

function Get-StorageAnalytics
{
	param 
   	(
		[Parameter(Mandatory = $true)]
		[string] $AccountName,
        [Parameter(Mandatory=$True)] $Mode
	)

    [XML]$resultXML = $null
    #-xmsversion "2013-08-15"
    $request = Create-StorageAccountRequest -accountName $AccountName -resourceType "blob.core" -operationString "?restype=service&comp=properties" -xmsversion "2014-02-14" -contentLength "" -restMethod "GET" -Mode $Mode
    
    try
    {
        $response = $request.GetResponse()
        if ($response.Headers.Count -gt 0)
        {
            # Parse the web response.
            $reader = new-object System.IO.StreamReader($response.GetResponseStream())
            [XML]$resultXML = $reader.ReadToEnd()
        }
         
        # Close the resources no longer needed.
        $response.Close()
        $reader.Close()
    }
    catch [System.Net.WebException]
    {
        $_.Exception.ToString()
        $data = $_.Exception.Response.GetResponseStream()
        $reader = new-object System.IO.StreamReader($data)
        $text = $reader.ReadToEnd();
        throw $_.Exception.ToString()
    }

    return $resultXML
}

function Set-StorageAnalytics
{
    [CmdletBinding()]
	param 
   	(
		[Parameter(Mandatory = $true)]
		[string] $AccountName,

		[Parameter(Mandatory = $true)]
        [XML] $StorageServiceProperties,

        [Parameter(Mandatory=$True)] $Mode
	)

    $requestBody = $StorageServiceProperties.InnerXml
    $request = Create-StorageAccountRequest -accountName $AccountName -resourceType "blob.core" -operationString "?restype=service&comp=properties" -xmsversion "2013-08-15" -contentLength $requestBody.Length -restMethod "PUT" -Mode $Mode
    try
    {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)
        $streamOut = $request.GetRequestStream()
	    $streamOut.Write($bytes, 0, $bytes.Length)
	    $streamOut.Flush()
	    $streamOut.Close()

        $response = $request.GetResponse()
        if ($response.Headers.Count -gt 0)
        {
            # Parse the web response.
            $reader = new-object System.IO.StreamReader($response.GetResponseStream())
            $resultXML = $reader.ReadToEnd()
        }
         
        # Close the resources no longer needed.
        $response.Close()
        $reader.Close()
    }
    catch [System.Net.WebException]
    {
        $_.Exception.ToString()
        $data = $_.Exception.Response.GetResponseStream()
        $reader = new-object System.IO.StreamReader($data)
        $text = $reader.ReadToEnd();
        $text
        throw $_.Exception.ToString()
    }
}

function Create-StorageAccountRequest
{
	[CmdletBinding()]
	param 
   	(
		[Parameter(Mandatory = $true)]
		[string] $accountName,

		[Parameter(Mandatory = $true)]
		[string] $resourceType,

		[Parameter(Mandatory = $true)]
        [AllowEmptyString()]
		[string] $operationString,

		[Parameter(Mandatory = $true)]
		[string] $xmsversion,

		[string] $contentLength,

		[Parameter(Mandatory = $true)]
		[string] $restMethod,

        [string] $resourceString,
        [Parameter(Mandatory=$True)] $Mode
	)

	$nl   = [char]10 # newLine
    $date = (Get-Date).ToUniversalTime().ToString("R")

    
    #$storage = Get-StorageAccountFromCache -StorageAccountName $accountName -Mode $Mode
    $azureTableEndpoint = Get-Endpoint -StorageAccountName $accountName -Mode $Mode
    
    $keys = Get-AzureStorageKeyFromCache -StorageAccountName $accountName -Mode $Mode

    Write-Verbose ("Creating storage account request for $accountName with $azureTableEndpoint and key length " + $keys.Length.ToString())

    [String] $azureHostString = [String]::Format("{0}.{1}.$azureTableEndpoint/", $accountName, $resourceType)
    [String] $azureUriString = [String]::Format("https://{0}{1}{2}", $azureHostString, $subscriptionId, $operationString)
    [Uri] $uri = New-Object System.Uri($azureUriString)	


    [String] $canonicalizedHeadersString = [String]::Format("{0}{1}{1}{1}{4}{1}{1}{1}{1}{1}{1}{1}{1}{1}x-ms-date:{2}{1}x-ms-version:{3}{1}",$restMethod, $nl, $date, $xmsversion, $contentLength)
    if ([String]::IsNullOrEmpty($resourceString))
    {
	    [String] $canonicalizedResourceString = [String]::Format("/{1}/{0}comp:properties{0}restype:service" ,$nl, $accountName)
    }
    else
    {
        [String] $canonicalizedResourceString = $resourceString
    }
	[String] $signatureString = $canonicalizedHeadersString + $canonicalizedResourceString
    Write-Verbose "Signature is $signatureString"

	# Encodes this string by using the HMAC-SHA256 algorithm and constructs the authorization header.
	[Byte[]] $unicodeKeyByteArray      = [System.Convert]::FromBase64String($keys)
	$hmacSha256               = new-object System.Security.Cryptography.HMACSHA256((,$unicodeKeyByteArray))
    
	# Encode the signature.
	[Byte[]] $signatureStringByteArray = [System.Text.Encoding]::UTF8.GetBytes($signatureString)
    [String] $signatureStringHash      = [System.Convert]::ToBase64String($hmacSha256.ComputeHash($signatureStringByteArray))
    
	# Build the authorization header.
    [String] $authorizationHeader = [String]::Format([CultureInfo]::InvariantCulture,"{0} {1}:{2}", "SharedKey", $accountName, $signatureStringHash)

    Write-Verbose "Signing request for $uri"
    # Create the request and specify attributes of the request.
    [System.Net.HttpWebRequest] $request = [System.Net.HttpWebRequest]::Create($uri)
         
    # Define the requred headers to specify the API version and operation type.
    $request.Headers.Add('x-ms-version', $xmsversion)
    $request.Method            = $restMethod
    #$request.ContentType       = $contentType
    #$request.Accept            = $contentType
    $request.AllowAutoRedirect = $false
    $request.ServicePoint.Expect100Continue = $false
    $request.Headers.Add("Authorization", $authorizationHeader)
	$request.Headers.Add("x-ms-date", $date)

    return $request
}

function Get-Endpoint
{
    param
    (
        $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
    )

    $storage = Get-StorageAccountFromCache -StorageAccountName $StorageAccountName -Mode $Mode
    $tableendpoint = Get-AzureSAPTableEndpoint -StorageAccount $storage -Mode $Mode
    $blobendpoint = Get-AzureSAPBlobEndpoint -StorageAccount $storage -Mode $Mode

    if ($tableendpoint -match "http://.*?\.table\.core\.(.*)/")
    {
        $azureTableEndpoint = $Matches[1]
    }
    elseif ($tableendpoint -match "https://.*?\.table\.core\.(.*)/")
    {
        $azureTableEndpoint = $Matches[1]
    }
    elseif ($blobendpoint -match "http://.*?\.blob\.core\.(.*)/")
    {
        $azureTableEndpoint = $Matches[1]
    }
    elseif ($blobendpoint -match "https://.*?\.blob\.core\.(.*)/")
    {
        $azureTableEndpoint = $Matches[1]
    }
    else
    {
        Write-Warning "Could not extract endpoint information from Azure Storage Account. Using default $AzureEndpoint"
        $azureTableEndpoint = $AzureEndpoint
    }
    return  $azureTableEndpoint
}

function Get-CoreEndpoint
{
    param
    (
        $StorageAccountName,
        [Parameter(Mandatory=$True)] $Mode
    )

    $azureTableEndpoint = Get-Endpoint -StorageAccountName $StorageAccountName -Mode $Mode
    return ("core." + $azureTableEndpoint)
}

$ErrorActionPreference = "Stop"
$CurrentScriptVersion = "2.0.0.0"
$missingGuestAgentWarning = "Provision Guest Agent is not installed on this Azure Virtual Machine. Please read the documentation on how to download and install the Provision Guest Agent. After you have installed the Provision Guest Agent, enable it with the Enable-ProvisionGuestAgent_GUI commandlet that is part of this Powershell Module."
$AzureEndpoint = "windows.net"


$ROLECONTENT = "IaaS"
$DISK_TYPE_PREMIUM = "Premium"
$DISK_TYPE_STANDARD = "Standard"
$DEPLOY_MODE_ASM = "ASM"
$DEPLOY_MODE_ARM = "ARM"
[string] $OS_WINDOWS = "Windows"
[string] $OS_LINUX = "Linux"

$EXTENSION_AEM = 
@{
	"$OS_WINDOWS$DEPLOY_MODE_ASM"=@{Publisher="Microsoft.AzureCAT.AzureEnhancedMonitoring";Name="AzureCATExtensionHandler";Version="2.*"};
	"$OS_WINDOWS$DEPLOY_MODE_ARM"=@{Publisher="Microsoft.AzureCAT.AzureEnhancedMonitoring";Name="AzureCATExtensionHandler";Version="2.2"};
	"$OS_LINUX$DEPLOY_MODE_ARM"=@{Publisher="Microsoft.OSTCExtensions";Name="AzureEnhancedMonitorForLinux";Version="3.0"};
}

$EXTENSION_WAD = 
@{
	"$OS_WINDOWS$DEPLOY_MODE_ASM"=@{Publisher="Microsoft.Azure.Diagnostics";Name="IaaSDiagnostics";Version="1.*"};
	"$OS_WINDOWS$DEPLOY_MODE_ARM"=@{Publisher="Microsoft.Azure.Diagnostics";Name="IaaSDiagnostics";Version="1.5"};	
	"$OS_LINUX$DEPLOY_MODE_ARM"=@{Publisher="Microsoft.OSTCExtensions";Name="LinuxDiagnostic";Version="2.2"};
}

#$PerformanceCounters = @(
#                 @{"counterSpecifier"="\Processor(_Total)\% Processor Time";"sampleRate" = "PT1M"}
#                @{"counterSpecifier"="\Processor Information(_Total)\Processor Frequency";"sampleRate"="PT1M"}
#		        @{"counterSpecifier"="\Memory\Available Bytes";"sampleRate"="PT1M"}
#		        @{"counterSpecifier"="\TCPv6\Segments Retransmitted/sec";"sampleRate"="PT1M"}
#		        @{"counterSpecifier"="\TCPv4\Segments Retransmitted/sec";"sampleRate"="PT1M"}		        
#		        @{"counterSpecifier"="\Network Interface(*)\Bytes Sent/sec";"sampleRate"="PT1M"}
#		        @{"counterSpecifier"="\Network Interface(*)\Bytes Received/sec";"sampleRate"="PT1M"}		       	       
#           )
				
$PerformanceCounters = @{
	"$OS_WINDOWS"=	@(
						@{"counterSpecifier"="\Processor(_Total)\% Processor Time";"sampleRate" = "PT1M"}
						@{"counterSpecifier"="\Processor Information(_Total)\Processor Frequency";"sampleRate"="PT1M"}
						@{"counterSpecifier"="\Memory\Available Bytes";"sampleRate"="PT1M"}
						@{"counterSpecifier"="\TCPv6\Segments Retransmitted/sec";"sampleRate"="PT1M"}
						@{"counterSpecifier"="\TCPv4\Segments Retransmitted/sec";"sampleRate"="PT1M"}		        
						@{"counterSpecifier"="\Network Interface(*)\Bytes Sent/sec";"sampleRate"="PT1M"}
						@{"counterSpecifier"="\Network Interface(*)\Bytes Received/sec";"sampleRate"="PT1M"}		       	       
					)
	"$OS_LINUX"=	@(
						@{"counterSpecifier"="\Processor\PercentProcessorTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentIdleTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentPrivilegedTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentInterruptTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentDPCTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentUserTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentNiceTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Processor\PercentIOWaitTime";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PercentUsedMemory";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\UsedMemory";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PercentAvailableMemory";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\AvailableMemory";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PercentUsedByCache";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PercentUsedSwap";"sampleRate" = "PT15S";"unit"="Percent";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\UsedSwap";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\AvailableSwap";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PagesPerSec";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PagesReadPerSec";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\Memory\PagesWrittenPerSec";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\AverageTransferTime";"sampleRate" = "PT15S";"unit"="Seconds";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\AverageReadTime";"sampleRate" = "PT15S";"unit"="Seconds";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\AverageWriteTime";"sampleRate" = "PT15S";"unit"="Seconds";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\TransfersPerSecond";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\ReadsPerSecond";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\WritesPerSecond";"sampleRate" = "PT15S";"unit"="CountPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\BytesPerSecond";"sampleRate" = "PT15S";"unit"="BytesPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\WriteBytesPerSecond";"sampleRate" = "PT15S";"unit"="BytesPerSecond";"annotation"="annotation"}
						@{"counterSpecifier"="\PhysicalDisk\AverageDiskQueueLength";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\BytesTotal";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\BytesTransmitted";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\BytesReceived";"sampleRate" = "PT15S";"unit"="Bytes";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\PacketsTransmitted";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\PacketsReceived";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\TotalRxErrors";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\TotalTxErrors";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
						@{"counterSpecifier"="\NetworkInterface\TotalCollisions";"sampleRate" = "PT15S";"unit"="Count";"annotation"="annotation"}
					)
}



[XML] $WADPublicConfig = @"    
    <WadCfg>
        <DiagnosticMonitorConfiguration overallQuotaInMB="4096">
			<PerformanceCounters scheduledTransferPeriod="PT1M" >
			</PerformanceCounters>				
		</DiagnosticMonitorConfiguration>
    </WadCfg>    
"@

$wadTableName = "WADPerformanceCountersTable"
$WADTableName = $wadTableName

[xml]$DefaultStorageAnalyticsConfig = @'
<StorageServiceProperties>
  <Logging>
    <Version>1.0</Version>
    <Delete>true</Delete>
    <Read>true</Read>
    <Write>true</Write>
    <RetentionPolicy>
      <Enabled>true</Enabled>
      <Days>12</Days>
    </RetentionPolicy>
  </Logging>
  <HourMetrics>
    <Version>1.0</Version>
    <Enabled>true</Enabled>
    <IncludeAPIs>true</IncludeAPIs>
    <RetentionPolicy>
      <Enabled>true</Enabled>
      <Days>13</Days>
    </RetentionPolicy>
  </HourMetrics>
  <MinuteMetrics>
    <Version>1.0</Version>
    <Enabled>true</Enabled>
    <IncludeAPIs>true</IncludeAPIs>
    <RetentionPolicy>
      <Enabled>true</Enabled>
      <Days>13</Days>
    </RetentionPolicy>
  </MinuteMetrics>
  <Cors />
</StorageServiceProperties>
'@

$MetricsHourPrimaryTransactionsBlob = "`$MetricsHourPrimaryTransactionsBlob"
$MetricsMinutePrimaryTransactionsBlob = "`$MetricsMinutePrimaryTransactionsBlob"

Export-ModuleMember -Function Update-VMConfigForSAP
Export-ModuleMember -Function Update-VMConfigForSAP_GUI
Export-ModuleMember -Function Test-VMConfigForSAP
Export-ModuleMember -Function Test-VMConfigForSAP_GUI
Export-ModuleMember -Function Enable-ProvisionGuestAgent_GUI
Export-ModuleMember -Function Enable-ProvisionGuestAgent

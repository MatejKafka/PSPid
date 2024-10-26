@{
	RootModule = 'PSPid.psm1'
	ModuleVersion = '0.1'
	GUID = 'f3fc72a9-7a6a-4456-af03-26d125865f15'
	Author = 'Matej Kafka'

	Description = 'PowerShell client for the Golemio API for the Prague public transport network.'

	FunctionsToExport = @('Get-PidTrip', 'Format-PidTrip', 'Get-PidDeparture', 'Invoke-Pid', 'Set-PidToken')
	CmdletsToExport = @()
	VariablesToExport = @()
	AliasesToExport = @('pid')

	FormatsToProcess = 'PSPid.Format.ps1xml'
}


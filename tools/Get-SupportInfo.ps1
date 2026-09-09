#requires -Version 5.1

[CmdletBinding()]
param()

function Get-EeaSupportInfo {
    [CmdletBinding()]
    param()

    $application = Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1'
    . $application
    $edgeVersion = 'Unavailable'
    try { $edgeVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Find-EeaEdge)).FileVersion }
    catch { }
    $signature = 'UnknownError'
    try { $signature = (Get-AuthenticodeSignature -LiteralPath $application).Status.ToString() }
    catch { }
    if ($signature -cnotin @('Valid', 'NotSigned', 'HashMismatch', 'NotTrusted', 'NotSupportedFileFormat', 'Incompatible', 'UnknownError')) { $signature = 'UnknownError' }
    if ($edgeVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { $edgeVersion = 'Unavailable' }
    [pscustomobject][ordered]@{
        Product = 'Easy Edge Apps'
        Version = (Get-EeaVersion).ToString(3)
        WindowsVersion = [Environment]::OSVersion.Version.ToString()
        OperatingSystem64Bit = [Environment]::Is64BitOperatingSystem
        Process64Bit = [Environment]::Is64BitProcess
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellEdition = $PSVersionTable.PSEdition
        InterfaceCulture = [Globalization.CultureInfo]::CurrentUICulture.Name
        EdgeVersion = $edgeVersion
        ManagerSignature = $signature
    }
}

if ($MyInvocation.InvocationName -ne '.') { Get-EeaSupportInfo | ConvertTo-Json }
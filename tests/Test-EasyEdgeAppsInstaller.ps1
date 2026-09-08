#requires -Version 5.1

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$MsiPath, [switch]$InstallLifecycle)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'EasyEdgeApps.ps1')
$packagePath = [IO.Path]::GetFullPath($MsiPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.InstallerTests.' + [Guid]::NewGuid().ToString('N'))
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null
$installedProduct = ''
$oldProduct = ''
$retainLogs = $false

function Assert-Installer {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-MsiRows {
    param($Database, [string]$Query, [string[]]$Columns)
    $view = $Database.OpenView($Query)
    try {
        [void]$view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try {
                $row = [ordered]@{}
                for ($columnIndex = 0; $columnIndex -lt $Columns.Count; $columnIndex++) { $row[$Columns[$columnIndex]] = $record.StringData($columnIndex + 1) }
                [pscustomobject]$row
            }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record) }
        }
    }
    finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
}

function Invoke-MsiStatement {
    param($Database, [string]$Query)
    $view = $Database.OpenView($Query)
    try { [void]$view.Execute() }
    finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
}

function Invoke-InstallerTest {
    param([string]$Arguments, [string]$Label, [int[]]$ExpectedExit = @(0))
    $logPath = Join-Path $testRoot ($Label + '.log')
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList ($Arguments + ' /qn /norestart REBOOT=ReallySuppress /l*v "' + $logPath + '"') -Wait -PassThru
    Assert-Installer ($process.ExitCode -in $ExpectedExit) ("MSI $Label returned $($process.ExitCode). Diagnostic log: $logPath")
}

try {
    $database = $installer.OpenDatabase($packagePath, 0)
    $properties = @{}
    foreach ($row in @(Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' @('Name', 'Value'))) { $properties[$row.Name] = $row.Value }
    Assert-Installer ($properties.ProductName -ceq 'Easy Edge Apps' -and $properties.ProductVersion -ceq (Get-EeaVersion).ToString(3)) 'MSI branding and version must match the application.'
    $expectedAuthor = 'Blake Drumm (blakedrumm@microsoft.com)'
    $scriptHelp = Get-Help (Join-Path $projectRoot 'EasyEdgeApps.ps1') -Full | Out-String -Width 4096
    Assert-Installer ($scriptHelp.Contains('Author: ' + $expectedAuthor)) 'Script help notes must include the full author name and email.'
    $licenseRows = @(Read-MsiRows $database "SELECT ``Text`` FROM ``Control`` WHERE ``Dialog_`` = 'WelcomeEulaDlg' AND ``Control`` = 'LicenseText'" @('Text'))
    Assert-Installer ($licenseRows.Count -eq 1) 'The installer must contain one visible license agreement.'
    Add-Type -AssemblyName System.Windows.Forms
    $licenseBox = New-Object Windows.Forms.RichTextBox
    try {
        $licenseBox.Rtf = $licenseRows[0].Text
        $sourceLicense = [IO.File]::ReadAllText((Join-Path $projectRoot 'LICENSE'))
        Assert-Installer ($licenseBox.Text.Contains($expectedAuthor)) 'The installer license agreement must include the full author name and email.'
        Assert-Installer ($licenseBox.Text.Replace("`r`n", "`n").TrimEnd() -ceq $sourceLicense.Replace("`r`n", "`n").TrimEnd()) 'The rendered installer agreement must retain the complete project license.'
    }
    finally { $licenseBox.Dispose() }
    Assert-Installer (-not $properties.ContainsKey('ALLUSERS') -or -not $properties.ALLUSERS) 'The MSI must install for the current user, not for the machine.'
    Assert-Installer (-not $properties.ContainsKey('ARPSYSTEMCOMPONENT') -or $properties.ARPSYSTEMCOMPONENT -ne '1') 'The installed application must not be hidden from Installed Apps.'
    Assert-Installer ($properties.UpgradeCode -ceq '{9D0AF71A-353C-4A88-A171-16249356093F}') 'The upgrade identity must remain stable across releases.'
    $files = @(Read-MsiRows $database 'SELECT `File`, `FileName` FROM `File`' @('Id', 'Name'))
    Assert-Installer ($files.Count -eq 4 -and @($files | Where-Object { $_.Id -in @('LauncherFile', 'ApplicationScript', 'ApplicationLicense', 'ApplicationNotices') }).Count -eq 4) 'The MSI must contain only the launcher, portable script, license, and notices.'
    $registryRows = @(Read-MsiRows $database 'SELECT `Root`, `Key` FROM `Registry`' @('Root', 'Key'))
    Assert-Installer (@($registryRows | Where-Object { $_.Root -cne '1' -or $_.Key -cne 'Software\EasyEdgeApps\Installer' }).Count -eq 0) 'Application-authored MSI registry writes must be installer markers in HKCU only.'
    $shortcuts = @(Read-MsiRows $database 'SELECT `Directory_`, `Target` FROM `Shortcut`' @('Directory', 'Target'))
    Assert-Installer ($shortcuts.Count -eq 1 -and $shortcuts[0].Directory -ceq 'ProgramMenuFolder' -and $shortcuts[0].Target -ceq '[INSTALLFOLDER]EasyEdgeApps.exe') 'The installer must create one manager shortcut, not rewrite website shortcuts.'
    $tables = @(Read-MsiRows $database 'SELECT `Name` FROM `_Tables`' @('Name'))
    Assert-Installer (@($tables | Where-Object { $_.Name -in @('ServiceInstall', 'ServiceControl', 'Environment') }).Count -eq 0) 'The MSI must not install services or change environment variables.'
    $customActions = @(Read-MsiRows $database 'SELECT `Action`, `Type` FROM `CustomAction`' @('Name', 'Type'))
    Assert-Installer (@($customActions | Where-Object { ([int]$_.Type -band 63) -notin @(1, 51) }).Count -eq 0) 'The MSI must not execute PowerShell, scripts, downloaded installers, or executable custom actions.'
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
    $database = $null
    Write-Host 'PASS: Author attribution in help and the complete installer license, MSI version, stable upgrade identity, per-user registration, limited payload, Start menu launcher, and no application-executing custom actions.'
    if (-not $InstallLifecycle) { return }
    Assert-Installer (-not (Test-Path -LiteralPath 'HKCU:\Software\EasyEdgeApps\Installer')) 'Lifecycle tests refuse to touch an existing Easy Edge Apps MSI installation.'
    [void][IO.Directory]::CreateDirectory($testRoot)
    $installDirectory = Join-Path $testRoot 'Installed'
    $programsDirectory = [Environment]::GetFolderPath('Programs')
    Assert-Installer (-not [IO.File]::Exists((Join-Path $programsDirectory 'Easy Edge Apps.lnk'))) 'Lifecycle tests refuse to overwrite an existing manager shortcut.'
    $directoryOptions = ' INSTALLFOLDER="' + $installDirectory + '"'
    $oldPackage = Join-Path $testRoot 'older-test-fixture.msi'
    [IO.File]::Copy($packagePath, $oldPackage)
    $oldProduct = [Guid]::NewGuid().ToString('B').ToUpperInvariant()
    $database = $installer.OpenDatabase($oldPackage, 1)
    Invoke-MsiStatement $database "UPDATE ``Property`` SET ``Value`` = '1.2.99' WHERE ``Property`` = 'ProductVersion'"
    Invoke-MsiStatement $database ("UPDATE ``Property`` SET ``Value`` = '" + $oldProduct + "' WHERE ``Property`` = 'ProductCode'")
    $upgradeRows = @(Read-MsiRows $database 'SELECT `UpgradeCode`, `VersionMin`, `VersionMax`, `Language`, `Attributes`, `Remove`, `ActionProperty` FROM `Upgrade`' @('UpgradeCode', 'VersionMin', 'VersionMax', 'Language', 'Attributes', 'Remove', 'ActionProperty'))
    Invoke-MsiStatement $database 'DELETE FROM `Upgrade`'
    foreach ($upgradeRow in $upgradeRows) {
        $columnNames = New-Object 'Collections.Generic.List[string]'
        $columnValues = New-Object 'Collections.Generic.List[string]'
        foreach ($field in $upgradeRow.PSObject.Properties) {
            if ([string]::IsNullOrEmpty($field.Value)) { continue }
            $value = $field.Value
            if ($field.Name -in @('VersionMin', 'VersionMax') -and $value -ceq $properties.ProductVersion) { $value = '1.2.99' }
            $columnNames.Add('`' + $field.Name + '`')
            if ($field.Name -ceq 'Attributes') { $columnValues.Add(([int]$value).ToString()) }
            else { $columnValues.Add("'" + $value.Replace("'", "''") + "'") }
        }
        Invoke-MsiStatement $database ('INSERT INTO `Upgrade` (' + ($columnNames -join ', ') + ') VALUES (' + ($columnValues -join ', ') + ')')
    }
    $summary = $database.SummaryInformation(1)
    try {
        $summary.GetType().InvokeMember('Property', [Reflection.BindingFlags]::SetProperty, $null, $summary, @([int]9, [Guid]::NewGuid().ToString('B').ToUpperInvariant()))
        $summary.Persist()
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($summary) }
    $database.Commit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
    $database = $null
    $installedProduct = $oldProduct
    Invoke-InstallerTest ('/i "' + $oldPackage + '"' + $directoryOptions) 'install-older'
    Assert-Installer ([IO.File]::Exists((Join-Path $installDirectory 'EasyEdgeApps.exe')) -and [IO.File]::Exists((Join-Path $programsDirectory 'Easy Edge Apps.lnk'))) 'Installation must create the manager and its Start menu entry in the selected test folders.'
    $unrelatedPath = Join-Path $installDirectory 'keep-unrelated.txt'
    [IO.File]::WriteAllText($unrelatedPath, 'Synthetic file not owned by the installer.')
    Invoke-InstallerTest ('/i "' + $packagePath + '"' + $directoryOptions) 'upgrade'
    $installedProduct = $properties.ProductCode
    Assert-Installer ($installer.ProductState($oldProduct) -eq -1 -and $installer.ProductState($installedProduct) -eq 5) 'A major upgrade must replace the older registration instead of installing side by side.'
    $installedScript = Join-Path $installDirectory 'EasyEdgeApps.ps1'
    Assert-Installer ((Get-FileHash -LiteralPath $installedScript).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $projectRoot 'EasyEdgeApps.ps1')).Hash) 'The installed script must match the tested application bytes.'
    $installedNotices = [IO.File]::ReadAllText((Join-Path $installDirectory 'THIRD-PARTY-NOTICES.md'))
    Assert-Installer ($installedNotices.StartsWith([IO.File]::ReadAllText((Join-Path $projectRoot 'THIRD-PARTY-NOTICES.md')), [StringComparison]::Ordinal) -and
        $installedNotices.EndsWith([IO.File]::ReadAllText((Join-Path $projectRoot 'installer\WiX-Notices.txt')), [StringComparison]::Ordinal)) 'The installer must retain the complete WiX and embedded-renderer license notices.'
    Assert-Installer ($installer.ProductInfo($installedProduct, 'ProductName') -ceq 'Easy Edge Apps' -and
        $installer.ProductInfo($installedProduct, 'VersionString') -ceq (Get-EeaVersion).ToString(3) -and
        $installer.ProductInfo($installedProduct, 'AssignmentType') -ceq '0') 'Windows Installer must register the application name and version for the current user.'
    $launcherAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $installDirectory 'EasyEdgeApps.exe')))
    $launcherType = $launcherAssembly.GetType('EasyEdgeApps.Launcher', $true)
    $startInfo = $launcherType.GetMethod('CreateStartInfo').Invoke($null, [object[]]@($installDirectory.PSObject.BaseObject, $env:WINDIR.PSObject.BaseObject))
    Assert-Installer ($startInfo.FileName -ceq (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -and $startInfo.CreateNoWindow -and -not $startInfo.UseShellExecute -and $startInfo.Arguments.EndsWith('-File "' + $installedScript + '"')) 'The manager must launch only its adjacent script with the trusted Windows interpreter and no console.'
    $launcherProbeDirectory = Join-Path $testRoot 'Launcher probe'
    [void][IO.Directory]::CreateDirectory($launcherProbeDirectory)
    $launcherProbePath = Join-Path $launcherProbeDirectory 'EasyEdgeApps.exe'
    [IO.File]::Copy((Join-Path $installDirectory 'EasyEdgeApps.exe'), $launcherProbePath)
    $launcherProbeScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -Name NativeConsole -Namespace EasyEdgeAppsLauncherTest -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
$launchFacts = [pscustomobject]@{
    Apartment = [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    Arguments = @($args).Count
    HasConsole = [EasyEdgeAppsLauncherTest.NativeConsole]::GetConsoleWindow() -ne [IntPtr]::Zero
    HostVersion = $PSVersionTable.PSVersion.ToString()
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launch.json'), ($launchFacts | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
'@
    [IO.File]::WriteAllText((Join-Path $launcherProbeDirectory 'EasyEdgeApps.ps1'), $launcherProbeScript, (New-Object Text.UTF8Encoding($false)))
    $probeStartInfo = New-Object Diagnostics.ProcessStartInfo
    $probeStartInfo.FileName = $launcherProbePath
    $probeStartInfo.Arguments = '--ignored-test-input'
    $probeStartInfo.UseShellExecute = $false
    $probeStartInfo.CreateNoWindow = $true
    $probeProcess = [Diagnostics.Process]::Start($probeStartInfo)
    try {
        if (-not $probeProcess.WaitForExit(20000)) { $probeProcess.Kill(); throw 'The test launcher did not finish within 20 seconds.' }
        Assert-Installer ($probeProcess.ExitCode -eq 0) 'The compiled launcher must successfully execute its adjacent script.'
    }
    finally { $probeProcess.Dispose() }
    $launchFacts = ConvertFrom-EeaJson ([IO.File]::ReadAllText((Join-Path $launcherProbeDirectory 'launch.json')))
    Assert-Installer ($launchFacts.Apartment -ceq 'STA' -and $launchFacts.Arguments -eq 0 -and -not $launchFacts.HasConsole -and $launchFacts.HostVersion.StartsWith('5.1.')) 'The real launcher must start Windows PowerShell 5.1 in STA mode without a console or arbitrary forwarded input.'
    Write-Host 'PASS: Compiled launcher starts its adjacent script in Windows PowerShell STA without a console or forwarded arguments.'
    Invoke-InstallerTest ('/i "' + $oldPackage + '"' + $directoryOptions) 'reject-downgrade' @(1603, 1638)
    Assert-Installer ($installer.ProductState($installedProduct) -eq 5 -and [IO.File]::Exists($installedScript)) 'Rejected downgrades must preserve the installed version.'
    [IO.File]::Delete($installedScript)
    Invoke-InstallerTest ('/famus ' + $installedProduct + $directoryOptions) 'repair'
    $repairLog = [IO.File]::ReadAllText((Join-Path $testRoot 'repair.log'))
    Assert-Installer ((Get-FileHash -LiteralPath $installedScript).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $projectRoot 'EasyEdgeApps.ps1')).Hash -and [IO.File]::Exists((Join-Path $programsDirectory 'Easy Edge Apps.lnk')) -and $repairLog.Contains('ShortcutCreate(')) 'MSI repair must restore the script and recreate the manager shortcut.'
    Invoke-InstallerTest ('/x ' + $installedProduct + $directoryOptions) 'uninstall'
    $installedProduct = ''
    Assert-Installer (-not [IO.File]::Exists($installedScript) -and -not [IO.File]::Exists((Join-Path $programsDirectory 'Easy Edge Apps.lnk')) -and [IO.File]::Exists($unrelatedPath)) 'Uninstall must remove only installed program files and its manager shortcut, preserving unrelated files.'
    Assert-Installer (-not (Test-Path -LiteralPath 'HKCU:\Software\EasyEdgeApps\Installer')) 'Uninstall must remove its own HKCU installer markers.'
    Write-Host 'PASS: Actual per-user MSI install, upgrade, downgrade rejection, repair, launcher configuration, Installed Apps registration, and uninstall preservation.'
}
catch { $retainLogs = $true; throw }
finally {
    if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
    foreach ($productCode in @($installedProduct, $oldProduct) | Where-Object { $_ } | Select-Object -Unique) {
        if ($installer.ProductState($productCode) -eq 5) {
            try { Invoke-InstallerTest ('/x ' + $productCode) 'cleanup' }
            catch { Write-Warning ('Test installation cleanup failed for ' + $productCode + '. Keep the test logs and uninstall this test product manually.') }
        }
    }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    if ([IO.Directory]::Exists($testRoot) -and -not $retainLogs) { [IO.Directory]::Delete($testRoot, $true) }
}
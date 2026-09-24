# New-UnattendXml.ps1
# Generates a Windows unattend.xml (windowsPE / specialize / oobeSystem
# passes) from explicit parameters. Every setting emitted below is a
# DOCUMENTED, SUPPORTED setup mechanism.
#
# MECHANISM SEPARATION POLICY
# ---------------------------
#  - "SUPPORTED MECHANISM" below: standard unattend components documented by
#    Microsoft (Microsoft-Windows-Shell-Setup, Microsoft-Windows-Setup,
#    Microsoft-Windows-International-Core[-WinPE]). These are emitted from
#    parameters with safe defaults; nothing controversial is hard-coded.
#  - "BUILD-SPECIFIC WORKAROUND" below: opt-in behavior that works around
#    build-specific setup limitations (e.g. Windows 11 Home/Pro 22H2+ forcing
#    a Microsoft account). These are emitted ONLY when the matching switch is
#    passed (-EnableBypassNRO) and are marked as workarounds in the XML
#    description field and in this header. Default: OFF.
#
# NOT INCLUDED (deliberately): telemetry/Defender/auto-update tampering has no
# supported unattend mechanism; those must be configured post-install via
# policy/Intune. Partitioning automation is destructive and is therefore not
# emitted by default (opt-in: -InstallToAvailablePartition, requires a
# pre-partitioned disk).
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only content; XML is written as
#                 BOM-less UTF-8 with an explicit XML declaration.
#
# Example:
#   .\New-UnattendXml.ps1 -ComputerName LAB01 -TimeZone "Pacific Standard Time" `
#       -LocalAccountName labuser -LocalAccountPassword "ChangeMe123!" -LocalAccountAdmin

[CmdletBinding()]
param(
    [string]$ComputerName = '',
    [string]$Language = 'en-US',
    [string]$KeyboardLayout = 'en-US',
    [string]$Region = 'en-US',
    [string]$TimeZone = '',
    [string]$LocalAccountName = '',
    [string]$LocalAccountPassword = '',
    [switch]$LocalAccountAdmin,
    [switch]$AutoLogon,
    [ValidateSet('Work', 'Home', 'Public')][string]$NetworkLocation = 'Work',
    [ValidateRange(0, 3)][int]$ProtectYourPC = 3,
    [switch]$HideWirelessSetupInOOBE,
    [switch]$HideOnlineAccountScreens,
    [switch]$SkipUserOOBE,
    [switch]$EnableBypassNRO,
    [switch]$InstallToAvailablePartition,
    [string]$ProductKey = '',
    [ValidateSet('amd64', 'x86', 'arm64')][string]$Architecture = 'amd64',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) { $OutputPath = 'D:\WimMount\Output\unattend.xml' }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

$createLocal = ($LocalAccountName -ne '')
$hideLocalAccountScreen = $createLocal
$hideOnline = [bool]$HideOnlineAccountScreens
if ($createLocal -and -not $HideOnlineAccountScreens) {
    # SUPPORTED MECHANISM: creating a local account implies the online-account
    # screens are irrelevant; hide them so OOBE does not dead-end on MSA.
    $hideOnline = $true
}
if ($createLocal -and -not $LocalAccountPassword) {
    Write-Warning 'LocalAccountName was provided without a password. The account will be created with a BLANK password (stored in plaintext in the XML). Strongly consider providing one.'
}

function Write-WinUnattendComponent {
    # SUPPORTED MECHANISM: standard unattend component envelope with the
    # documented wcm/xsi namespace declarations.
    param($Writer, [string]$Pass, [string]$Name, [string]$Architecture, [scriptblock]$Body)
    $Writer.WriteStartElement('component')
    $Writer.WriteAttributeString('name', $Name)
    $Writer.WriteAttributeString('processorArchitecture', $Architecture)
    $Writer.WriteAttributeString('publicKeyToken', '31bf3856ad364e35')
    $Writer.WriteAttributeString('language', 'neutral')
    $Writer.WriteAttributeString('versionScope', 'nonSxS')
    $Writer.WriteAttributeString('xmlns', 'wcm', 'http://www.w3.org/2000/xmlns/', 'http://schemas.microsoft.com/WMIConfig/2002/State')
    $Writer.WriteAttributeString('xmlns', 'xsi', 'http://www.w3.org/2000/xmlns/', 'http://www.w3.org/2001/XMLSchema-instance')
    & $Body
    $Writer.WriteEndElement()
}

function Write-WinUnattendElement {
    param($Writer, [string]$Name, [string]$Value, [string]$ChildName = '', [string]$ChildValue = '')
    if ($Value -eq '' -and $ChildValue -eq '') { return }
    $Writer.WriteStartElement($Name)
    if ($ChildName -ne '') {
        $Writer.WriteElementString($ChildName, $ChildValue)
    }
    else {
        $Writer.WriteString($Value)
    }
    $Writer.WriteEndElement()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = $utf8NoBom
$w = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
try {
    $w.WriteStartDocument()
    $w.WriteStartElement('unattend', 'urn:schemas-microsoft-com:unattend')

    # ------------------------------------------------------------------
    # windowsPE pass
    # ------------------------------------------------------------------
    $w.WriteStartElement('settings')
    $w.WriteAttributeString('pass', 'windowsPE')

    # SUPPORTED MECHANISM: language/region/keyboard for the setup UI itself.
    Write-WinUnattendComponent -Writer $w -Pass 'windowsPE' -Name 'Microsoft-Windows-International-Core-WinPE' -Architecture $Architecture -Body {
        Write-WinUnattendElement -Writer $w -Name 'SetupUILanguage' -ChildName 'UILanguage' -ChildValue $Language
        Write-WinUnattendElement -Writer $w -Name 'InputLocale' -Value $KeyboardLayout
        Write-WinUnattendElement -Writer $w -Name 'SystemLocale' -Value $Language
        Write-WinUnattendElement -Writer $w -Name 'UILanguage' -Value $Language
        Write-WinUnattendElement -Writer $w -Name 'UserLocale' -Value $Region
    }

    # SUPPORTED MECHANISM: setup behavior (EULA acceptance, optional product
    # key for edition selection, optional non-destructive install target).
    Write-WinUnattendComponent -Writer $w -Pass 'windowsPE' -Name 'Microsoft-Windows-Setup' -Architecture $Architecture -Body {
        $w.WriteStartElement('UserData')
        Write-WinUnattendElement -Writer $w -Name 'AcceptEula' -Value 'true'
        if ($ProductKey) {
            # A generic/retail key here selects an edition; it does not activate.
            Write-WinUnattendElement -Writer $w -Name 'ProductKey' -ChildName 'Key' -ChildValue $ProductKey
        }
        $w.WriteEndElement()
        if ($InstallToAvailablePartition) {
            # SUPPORTED MECHANISM: install to the first available partition.
            # Requires a pre-partitioned/formatted disk; emits no partitioning
            # automation (that would be destructive and is out of scope).
            $w.WriteStartElement('ImageInstall')
            $w.WriteStartElement('OSImage')
            Write-WinUnattendElement -Writer $w -Name 'InstallToAvailablePartition' -Value 'true'
            $w.WriteEndElement()
            $w.WriteEndElement()
        }
    }
    $w.WriteEndElement()

    # ------------------------------------------------------------------
    # specialize pass
    # ------------------------------------------------------------------
    $w.WriteStartElement('settings')
    $w.WriteAttributeString('pass', 'specialize')

    # SUPPORTED MECHANISM: system language/region/keyboard defaults.
    Write-WinUnattendComponent -Writer $w -Pass 'specialize' -Name 'Microsoft-Windows-International-Core' -Architecture $Architecture -Body {
        Write-WinUnattendElement -Writer $w -Name 'InputLocale' -Value $KeyboardLayout
        Write-WinUnattendElement -Writer $w -Name 'SystemLocale' -Value $Language
        Write-WinUnattendElement -Writer $w -Name 'UILanguage' -Value $Language
        Write-WinUnattendElement -Writer $w -Name 'UserLocale' -Value $Region
    }

    Write-WinUnattendComponent -Writer $w -Pass 'specialize' -Name 'Microsoft-Windows-Shell-Setup' -Architecture $Architecture -Body {
        if ($ComputerName) {
            # SUPPORTED MECHANISM: static computer name (omit to let setup
            # generate one).
            Write-WinUnattendElement -Writer $w -Name 'ComputerName' -Value $ComputerName
        }
        if ($TimeZone) {
            # SUPPORTED MECHANISM: Windows time zone id (e.g. "Pacific
            # Standard Time", "China Standard Time"). Omitted -> setup default.
            Write-WinUnattendElement -Writer $w -Name 'TimeZone' -Value $TimeZone
        }
        if ($AutoLogon) {
            # SUPPORTED MECHANISM (use with care): one-time auto logon after
            # OOBE completes. Credentials are stored in plaintext in this file;
            # LogonCount=1 limits exposure. Delete the file after deployment.
            $w.WriteStartElement('AutoLogon')
            Write-WinUnattendElement -Writer $w -Name 'Enabled' -Value 'true'
            Write-WinUnattendElement -Writer $w -Name 'LogonCount' -Value '1'
            Write-WinUnattendElement -Writer $w -Name 'Username' -Value $LocalAccountName
            $w.WriteStartElement('Password')
            Write-WinUnattendElement -Writer $w -Name 'Value' -Value $LocalAccountPassword
            Write-WinUnattendElement -Writer $w -Name 'PlainText' -Value 'true'
            $w.WriteEndElement()
            $w.WriteEndElement()
        }
    }
    $w.WriteEndElement()

    # ------------------------------------------------------------------
    # oobeSystem pass
    # ------------------------------------------------------------------
    $w.WriteStartElement('settings')
    $w.WriteAttributeString('pass', 'oobeSystem')

    Write-WinUnattendComponent -Writer $w -Pass 'oobeSystem' -Name 'Microsoft-Windows-Shell-Setup' -Architecture $Architecture -Body {
        # SUPPORTED MECHANISM: OOBE automation and privacy (ProtectYourPC is
        # the documented 0-3 slider; 3 = recommended settings). No telemetry
        # or Defender settings are touched anywhere in this file.
        $w.WriteStartElement('OOBE')
        Write-WinUnattendElement -Writer $w -Name 'HideEULAPage' -Value 'true'
        Write-WinUnattendElement -Writer $w -Name 'HideLocalAccountScreen' -Value $(if ($hideLocalAccountScreen) { 'true' } else { 'false' })
        Write-WinUnattendElement -Writer $w -Name 'HideOEMRegistrationScreen' -Value 'true'
        Write-WinUnattendElement -Writer $w -Name 'HideOnlineAccountScreens' -Value $(if ($hideOnline) { 'true' } else { 'false' })
        Write-WinUnattendElement -Writer $w -Name 'HideWirelessSetupInOOBE' -Value $(if ($HideWirelessSetupInOOBE) { 'true' } else { 'false' })
        Write-WinUnattendElement -Writer $w -Name 'NetworkLocation' -Value $NetworkLocation
        Write-WinUnattendElement -Writer $w -Name 'ProtectYourPC' -Value ([string]$ProtectYourPC)
        Write-WinUnattendElement -Writer $w -Name 'SkipMachineOOBE' -Value 'true'
        Write-WinUnattendElement -Writer $w -Name 'SkipUserOOBE' -Value $(if ($SkipUserOOBE) { 'true' } else { 'false' })
        $w.WriteEndElement()

        if ($createLocal) {
            # SUPPORTED MECHANISM: local account creation. Admin membership is
            # opt-in (-LocalAccountAdmin); password is stored in plaintext per
            # the unattend schema - remove this file after deployment.
            $w.WriteStartElement('UserAccounts')
            $w.WriteStartElement('LocalAccounts')
            $w.WriteStartElement('LocalAccount')
            $w.WriteAttributeString('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add')
            $w.WriteStartElement('Password')
            Write-WinUnattendElement -Writer $w -Name 'Value' -Value $LocalAccountPassword
            Write-WinUnattendElement -Writer $w -Name 'PlainText' -Value 'true'
            $w.WriteEndElement()
            Write-WinUnattendElement -Writer $w -Name 'Description' -Value 'Local account created by WinISO servicing toolchain unattend'
            Write-WinUnattendElement -Writer $w -Name 'DisplayName' -Value $LocalAccountName
            Write-WinUnattendElement -Writer $w -Name 'Group' -Value $(if ($LocalAccountAdmin) { 'Administrators' } else { 'Users' })
            Write-WinUnattendElement -Writer $w -Name 'Name' -Value $LocalAccountName
            $w.WriteEndElement()
            $w.WriteEndElement()
            $w.WriteEndElement()
        }

        if ($EnableBypassNRO) {
            # BUILD-SPECIFIC WORKAROUND (opt-in, NOT a supported unattend
            # setting): Windows 11 22H2+ Home/Pro OOBE can refuse to continue
            # without a Microsoft account. Setting the BypassNRO registry
            # value before OOBE starts re-enables the local-account path.
            # This modifies the registry during first logon; it is emitted
            # ONLY because -EnableBypassNRO was passed explicitly.
            $w.WriteStartElement('FirstLogonCommands')
            $w.WriteStartElement('SynchronousCommand')
            $w.WriteAttributeString('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add')
            Write-WinUnattendElement -Writer $w -Name 'Order' -Value '1'
            Write-WinUnattendElement -Writer $w -Name 'Description' -Value 'BUILD-SPECIFIC WORKAROUND (opt-in): re-enable local-account path in Windows 11 22H2+ OOBE via BypassNRO'
            Write-WinUnattendElement -Writer $w -Name 'CommandLine' -Value 'reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f'
            $w.WriteEndElement()
            $w.WriteEndElement()
        }
    }
    $w.WriteEndElement()

    $w.WriteEndElement()  # unattend
    $w.WriteEndDocument()
    $w.Flush()
}
finally {
    $w.Close()
}

# Validate: the file must be well-formed XML before we hand it to setup.
try {
    [void]([xml](Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8))
}
catch {
    throw ('Generated unattend.xml failed XML validation: ' + $_.Exception.Message)
}

[pscustomobject]@{
    Path                      = $OutputPath
    ComputerName              = $ComputerName
    Language                  = $Language
    Region                    = $Region
    KeyboardLayout            = $KeyboardLayout
    TimeZone                  = $TimeZone
    LocalAccountConfigured    = $createLocal
    LocalAccountIsAdmin       = [bool]$LocalAccountAdmin
    AutoLogonEnabled          = [bool]$AutoLogon
    WorkaroundApplied         = [bool]$EnableBypassNRO
    InstallToAvailablePartition = [bool]$InstallToAvailablePartition
    HideOnlineAccountScreens  = $hideOnline
}

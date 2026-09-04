#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Exec', 'Tunnel', 'Doctor')]
    [string]$Mode = 'Exec',
    [string]$VmHost = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_VM_HOST)) { '10.127.1.109' } else { $env:ALIST_VM_HOST }),
    [string]$VmUser = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_VM_USER)) { 'kuroega' } else { $env:ALIST_VM_USER }),
    [ValidateRange(1, 65535)]
    [int]$SshPort = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_VM_SSH_PORT)) { 22 } else { $env:ALIST_VM_SSH_PORT }),
    [string]$IdentityFile = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_VM_IDENTITY_FILE)) { '' } else { $env:ALIST_VM_IDENTITY_FILE }),
    [string]$KnownHostsFile = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_VM_KNOWN_HOSTS_FILE)) { '' } else { $env:ALIST_VM_KNOWN_HOSTS_FILE }),
    [string]$SshPath = $(if ([string]::IsNullOrWhiteSpace($env:ALIST_SSH_PATH)) { 'ssh.exe' } else { $env:ALIST_SSH_PATH }),
    [Alias('Command')]
    [string]$RemoteCommand = '',
    [ValidateRange(1, 65535)]
    [int]$LocalHttpPort = 15244,
    [ValidateRange(1, 65535)]
    [int]$RemoteHttpPort = 5244,
    [switch]$TunnelHttp,
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-SafeToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\s''"]') {
        throw "$Name must be a non-empty value without whitespace or quotes."
    }
}

function Resolve-OptionalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Cannot find OpenSSH client '$Name'. Install the Windows OpenSSH Client or set -SshPath."
    }

    return $command.Source
}

function Format-DryRunArguments {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object { "[$_]" }) -join ' ')
}

Assert-SafeToken -Value $VmHost -Name 'VmHost'
Assert-SafeToken -Value $VmUser -Name 'VmUser'

$identityPath = Resolve-OptionalPath -Path $IdentityFile
$knownHostsPath = Resolve-OptionalPath -Path $KnownHostsFile

if ($identityPath -and -not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
    throw "Identity file does not exist: $identityPath"
}

if ($knownHostsPath -and -not (Test-Path -LiteralPath $knownHostsPath -PathType Leaf)) {
    throw "Known hosts file does not exist: $knownHostsPath"
}

$sshExecutable = Resolve-Executable -Name $SshPath
$target = "$VmUser@$VmHost"

if ($Mode -eq 'Doctor') {
    Write-Output "OpenSSH client: $sshExecutable"
    Write-Output "SSH target: ${target}:$SshPort"
    if ($identityPath) {
        Write-Output "Identity file: $identityPath"
    }
    if ($knownHostsPath) {
        Write-Output "Known hosts file: $knownHostsPath"
    }

    $testNetConnection = Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue
    if ($null -eq $testNetConnection) {
        Write-Warning 'Test-NetConnection is unavailable; skipped the TCP reachability check.'
        exit 0
    }

    $reachable = Test-NetConnection -ComputerName $VmHost -Port $SshPort -InformationLevel Quiet
    if (-not $reachable) {
        throw "Cannot reach ${VmHost}:$SshPort. Start AListBackend and check VMware networking."
    }

    Write-Output "TCP ${VmHost}:$SshPort is reachable."
    exit 0
}

if ($Mode -eq 'Exec' -and [string]::IsNullOrWhiteSpace($RemoteCommand)) {
    throw '-RemoteCommand (or -Command) is required when -Mode Exec is selected.'
}

if ($Mode -ne 'Exec' -and -not [string]::IsNullOrWhiteSpace($RemoteCommand)) {
    throw '-RemoteCommand is only valid when -Mode Exec is selected.'
}

$sshArguments = @(
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    '-p', "$SshPort"
)

if ($knownHostsPath) {
    $sshArguments += @('-o', "UserKnownHostsFile=$knownHostsPath")
}

if ($identityPath) {
    $sshArguments += @('-i', $identityPath, '-o', 'IdentitiesOnly=yes')
}

if ($Mode -eq 'Exec' -or $Mode -eq 'Tunnel') {
    $sshArguments += @('-o', 'BatchMode=yes')
}

$httpTunnelRequested = $TunnelHttp -or $Mode -eq 'Tunnel'
if ($httpTunnelRequested) {
    $sshArguments += @(
        '-o', 'ExitOnForwardFailure=yes',
        '-L', "127.0.0.1:$LocalHttpPort`:127.0.0.1:$RemoteHttpPort"
    )
}

switch ($Mode) {
    'Exec' {
        $sshArguments += '-T'
    }
    'Tunnel' {
        $sshArguments += @('-N', '-T')
    }
}

$sshArguments += $target
if ($Mode -eq 'Exec') {
    $sshArguments += $RemoteCommand
}

if ($DryRun) {
    Write-Output "ssh $((Format-DryRunArguments -Arguments $sshArguments))"
    if ($httpTunnelRequested) {
        Write-Output "Local AList URL: http://127.0.0.1:$LocalHttpPort"
    }
    exit 0
}

if ($httpTunnelRequested) {
    Write-Verbose "Forwarding 127.0.0.1:$LocalHttpPort to VM 127.0.0.1:$RemoteHttpPort."
}

& $sshExecutable @sshArguments
$sshExitCode = $LASTEXITCODE
if ($sshExitCode -ne 0) {
    exit $sshExitCode
}

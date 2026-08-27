# Tailscale Full Setup - Windows Server
# Run PowerShell as Administrator.
# Auth keys are requested interactively and never stored in this repository.

$ErrorActionPreference = 'Continue'

function Info($s){ Write-Host $s -ForegroundColor Cyan }
function Ok($s){ Write-Host "[OK] $s" -ForegroundColor Green }
function Warn($s){ Write-Host "[!] $s" -ForegroundColor Yellow }
function Need-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Run PowerShell as Administrator.' -ForegroundColor Red; return $false }
    return $true
}
function TailscalePath {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach($c in @("$env:ProgramFiles\Tailscale\tailscale.exe","${env:ProgramFiles(x86)}\Tailscale\tailscale.exe","$env:LOCALAPPDATA\Tailscale\tailscale.exe")){ if(Test-Path $c){ return $c } }
    return $null
}
function Refresh-Path {
    $paths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData\Tailscale") | Where-Object { $_ }
    $env:Path = (($env:Path -split ';') + $paths | Select-Object -Unique) -join ';'
}
function Install-TS {
    Refresh-Path
    if (TailscalePath) { Ok "Tailscale is already installed."; return $true }
    Info 'Installing Tailscale via winget...'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { Warn 'winget is unavailable. Install Tailscale manually, then rerun this script.'; return $false }
    winget install --id Tailscale.Tailscale --exact --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (-not (TailscalePath)) { Warn 'Tailscale installation completed but tailscale.exe could not be found.'; return $false }
    Ok "Tailscale installed: $(& (TailscalePath) version | Select-Object -First 1)"; return $true
}
function Ensure-TS {
    Refresh-Path; $p=TailscalePath
    if (-not $p) { if (-not (Install-TS)) { return $null }; $p=TailscalePath }
    if (-not $p) { Warn 'tailscale.exe is still unavailable after installation.'; return $null }
    $svc=Get-Service tailscaled -ErrorAction SilentlyContinue
    if($svc -and $svc.Status -ne 'Running'){Start-Service tailscaled -ErrorAction SilentlyContinue}
    return $p
}
function Connected($p){ $ip=& $p ip -4 2>$null | Where-Object {$_ -match '^100\.'}; return [bool]$ip }
function Set-TSHostname($p){
    $default='exit-node'; $current=& $p status --json 2>$null | Out-String
    if($current -match '"HostName"\s*:\s*"([^"]+)"'){ $currentName=$matches[1] } else { $currentName='unknown' }
    Write-Host "Current Tailscale hostname: $currentName"
    $requested=Read-Host "Tailscale hostname [$default]"; if([string]::IsNullOrWhiteSpace($requested)){$requested=$default}
    $name=($requested.ToLower() -replace '[^a-z0-9-]+','-' -replace '^-+','' -replace '-+$','' -replace '-{2,}','-')
    if([string]::IsNullOrWhiteSpace($name)){$name=$default}; if($name.Length -gt 63){$name=$name.Substring(0,63).TrimEnd('-')}
    & $p set --hostname=$name
    if($LASTEXITCODE -eq 0){Ok "Tailscale hostname: $name"; return $true}
    Warn 'Could not set Tailscale hostname.'; return $false
}
function Join-IfNeeded($p){
    if(Connected $p){return $true}
    $secure=Read-Host 'Tailscale Auth Key' -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{$key=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try{& $p up --auth-key=$key --accept-dns=false;if($LASTEXITCODE -ne 0){Warn 'Tailscale authentication failed.';return $false}}finally{$key=$null}
    if(-not (Connected $p)){Warn 'Join failed or no Tailscale IPv4 was detected.';return $false}
    Ok 'Joined Tailnet.'; Set-TSHostname $p | Out-Null; return $true
}
function Setup-Exit($p){
    if(-not (Join-IfNeeded $p)){return}
    Info 'Enabling Windows IP forwarding...'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -Type DWord -Value 1
    Info 'Configuring Exit Node identity...'
    $secure=Read-Host 'Tailscale Auth Key (required to apply tag:exit)' -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{$key=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try{& $p up --auth-key=$key --accept-dns=false --advertise-exit-node --advertise-tags=tag:exit;if($LASTEXITCODE -ne 0){Warn 'Exit Node authentication/tagging failed. Make sure the auth key is allowed to use tag:exit.';return}}finally{$key=$null}
    & $p set --advertise-exit-node=true
    if($LASTEXITCODE -ne 0){Warn 'Exit Node advertisement could not be enabled.';return}
    Set-TSHostname $p | Out-Null
    $status=& $p status --json 2>$null | Out-String
    if($status -match 'tag:exit'){Ok 'Exit Node configured with tag:exit.'}else{Warn 'Exit Node is enabled, but tag:exit could not be verified in local status.'}
}
function Setup-SSH($p){if(-not (Join-IfNeeded $p)){return};& $p set --ssh;if($LASTEXITCODE -eq 0){Ok 'Tailscale SSH enabled.'}else{Warn 'This Tailscale build did not accept --ssh on Windows Server.'}}
function Get-PublicIP{$v4='Unavailable';$v6='Unavailable';try{$v4=(Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 5)}catch{};try{$v6=(Invoke-RestMethod 'https://api64.ipify.org' -TimeoutSec 5)}catch{};"Public IPv4 : $v4";"Public IPv6 : $v6"}
function Netcheck($p){if(Join-IfNeeded $p){& $p netcheck}}
function Ping-Test($p){if(-not(Join-IfNeeded $p)){return};$json=& $p status --json 2>$null|Out-String;try{$d=$json|ConvertFrom-Json}catch{Warn 'Could not parse Tailscale peer status.';return};$self=@($d.Self.TailscaleIPs);$direct=0;$derp=0;$total=0;foreach($peer in $d.Peer.PSObject.Properties.Value){$ip=@($peer.TailscaleIPs)[0];if(-not $ip -or $self -contains $ip){continue};$name=if($peer.HostName){$peer.HostName}else{$peer.DNSName};$total++;Write-Host "--- $name ($ip) ---";$out=& $p ping --c=3 $ip 2>&1|Out-String;Write-Host $out;if($out -match 'via DERP'){$derp++}elseif($out -match 'via .*:'){$direct++}};Info "Summary: $direct Direct / $derp DERP / $total peers"}
function Status($p){if(-not(Join-IfNeeded $p)){return};& $p status;Write-Host "`nTailscale IPv4:";& $p ip -4;Write-Host "Tailscale IPv6:";& $p ip -6;Write-Host "`nPublic IP:";Get-PublicIP}
function Exit-IP($p){if($p=Ensure-TS){Info 'Current public IPs (verify while a client is using this node as Exit Node):';Get-PublicIP}}
function Health($p){if(-not(Join-IfNeeded $p)){return};Info '=== Exit Node Health ===';$svc=Get-Service tailscaled -ErrorAction SilentlyContinue;if($svc -and $svc.Status -eq 'Running'){Ok 'Tailscale service: active'}else{Warn 'Tailscale service: not active'};$router=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter;if($router -eq 1){Ok 'IPv4 routing: enabled'}else{Warn 'IPv4 routing: disabled'};& $p status;Get-PublicIP}
function MTU-Test($p){if(-not(Join-IfNeeded $p)){return};$target=Read-Host 'Peer Tailscale IPv4 (100.x.x.x)';if($target -notmatch '^100\.[0-9]+\.[0-9]+\.[0-9]+$'){Warn 'Invalid Tailscale IPv4.';return};foreach($size in 1472,1400,1300,1200){ping.exe -n 2 -f -l $size $target 2>&1|Out-Null;if($LASTEXITCODE -eq 0){Ok "Payload $size bytes: OK"}else{Warn "Payload $size bytes: failed"}}}
function DNS-Test{Info '=== DNS Test ===';Get-DnsClientServerAddress -AddressFamily IPv4,IPv6|Format-Table -AutoSize;foreach($h in 'controlplane.tailscale.com','tailscale.com'){try{Resolve-DnsName $h -ErrorAction Stop|Out-Null;Ok "$h resolves"}catch{Warn "$h does not resolve"}}}
function Full-Benchmark($p){if(-not(Join-IfNeeded $p)){return};Info '=== VPS Quick Benchmark ===';"Hostname    : $env:COMPUTERNAME";Get-PublicIP;"Tailscale IPv4: $(& $p ip -4)";"Tailscale IPv6: $(& $p ip -6)";Write-Host '`nNetwork';& $p netcheck;Write-Host '`nPeer connectivity';Ping-Test $p;Write-Host '`nExit Node health';Health $p}
function Logout($p){Warn 'This logs this Windows Server out of the Tailnet.';if((Read-Host 'Type YES to confirm') -eq 'YES'){& $p logout;Ok 'Device logged out.'}else{Write-Host 'Cancelled.'}}
function Uninstall-TS($p){Warn 'This removes Tailscale from this Windows Server.';if((Read-Host 'Type UNINSTALL to confirm') -ne 'UNINSTALL'){Write-Host 'Cancelled.';return};& $p logout 2>$null;$pkg=Get-Package -Name *Tailscale* -ErrorAction SilentlyContinue;if($pkg){$pkg|Uninstall-Package -Force -ErrorAction SilentlyContinue};Ok 'Uninstall requested. Verify Programs/Apps if the installer remains.'}

if(-not(Need-Admin)){exit 1}
while($true){
    Clear-Host
    Write-Host '╔══════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║       Tailscale Full Setup - Windows     ║' -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1) Install Tailscale';Write-Host '  2) Setup Exit Node (IPv4 + IPv6)';Write-Host '  3) Enable Tailscale SSH';Write-Host '  4) Ping / Direct-DERP Test';Write-Host '  5) Network Benchmark (netcheck)';Write-Host '  6) Show Status + Public IP';Write-Host '  7) Logout / Remove This Device';Write-Host '  8) Exit IP Test';Write-Host '  9) Exit Node Health Check';Write-Host ' 10) MTU Test';Write-Host ' 11) DNS Test';Write-Host ' 12) Full VPS Benchmark';Write-Host ' 13) Uninstall Tailscale';Write-Host ' 14) Change Tailscale Hostname';Write-Host '  0) Exit';Write-Host ''
    $c=Read-Host 'Select an option';$p=TailscalePath
    switch($c){'1'{Install-TS};'2'{if($p=Ensure-TS){Setup-Exit $p}};'3'{if($p=Ensure-TS){Setup-SSH $p}};'4'{if($p=Ensure-TS){Ping-Test $p}};'5'{if($p=Ensure-TS){Netcheck $p}};'6'{if($p=Ensure-TS){Status $p}};'7'{if($p=Ensure-TS){Logout $p}};'8'{Exit-IP $p};'9'{if($p=Ensure-TS){Health $p}};'10'{if($p=Ensure-TS){MTU-Test $p}};'11'{DNS-Test};'12'{if($p=Ensure-TS){Full-Benchmark $p}};'13'{if($p=Ensure-TS){Uninstall-TS $p}};'14'{if($p=Ensure-TS){Set-TSHostname $p|Out-Null}};'0'{break};default{Warn 'Invalid option.'}}
    if($c -eq '0'){break};Write-Host '';Read-Host 'Press Enter to return to menu'|Out-Null
}

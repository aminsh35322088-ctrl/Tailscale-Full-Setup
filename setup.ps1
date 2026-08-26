# Tailscale Full Setup - Windows Server
# Run PowerShell as Administrator.
# Auth keys are requested interactively and never stored in this repository.

$ErrorActionPreference = 'Continue'

function Info($s){ Write-Host $s -ForegroundColor Cyan }
function Ok($s){ Write-Host "[OK] $s" -ForegroundColor Green }
function Warn($s){ Write-Host "[!] $s" -ForegroundColor Yellow }
function Need-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Run PowerShell as Administrator.' -ForegroundColor Red
        return $false
    }
    return $true
}
function TailscalePath {
    $p = (Get-Command tailscale.exe -ErrorAction SilentlyContinue).Source
    if ($p) { return $p }
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    foreach($c in $candidates){ if(Test-Path $c){ return $c } }
    return $null
}
function Install-TS {
    if (TailscalePath) { Ok "Tailscale is already installed."; return $true }
    Info 'Installing Tailscale via winget...'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Warn 'winget is unavailable. Install Tailscale manually from tailscale.com, then rerun this script.'
        return $false
    }
    winget install --id Tailscale.Tailscale --exact --accept-package-agreements --accept-source-agreements
    if (-not (TailscalePath)) { Warn 'Tailscale installation could not be verified.'; return $false }
    Ok 'Tailscale installed.'
    return $true
}
function Ensure-TS {
    $p = TailscalePath
    if (-not $p) { if (-not (Install-TS)) { return $null }; $p = TailscalePath }
    $svc = Get-Service tailscaled -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service tailscaled -ErrorAction SilentlyContinue }
    return $p
}
function Connected($p) {
    $ip = & $p ip -4 2>$null
    $ip = $ip | Where-Object { $_ -match '^100\.' }
    return [bool]$ip
}
function Join-IfNeeded($p) {
    if (Connected $p) { return $true }
    $secure = Read-Host 'Tailscale Auth Key' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr); & $p up --auth-key=$key --accept-dns=false }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $key = $null }
    if (-not (Connected $p)) { Warn 'Join failed or no Tailscale IPv4 was detected.'; return $false }
    Ok 'Joined Tailnet.'; return $true
}
function Setup-Exit($p) {
    if (-not (Join-IfNeeded $p)) { return }
    Info 'Enabling Windows IP forwarding...'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -Type DWord -Value 1
    & $p set --advertise-exit-node
    & $p set --advertise-tags=tag:exit
    Ok 'Exit Node configured with tag:exit.'
}
function Setup-SSH($p) {
    if (-not (Join-IfNeeded $p)) { return }
    & $p set --ssh
    Ok 'Tailscale SSH requested.'
    Warn 'If this Tailscale build does not support SSH on Windows Server, use standard Windows OpenSSH over the Tailscale IP instead.'
}
function Get-PublicIP {
    $v4='Unavailable'; $v6='Unavailable'
    try { $v4=(Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 5) } catch {}
    try { $v6=(Invoke-RestMethod 'https://api64.ipify.org' -TimeoutSec 5) } catch {}
    "Public IPv4 : $v4"; "Public IPv6 : $v6"
}
function Netcheck($p) { if(Join-IfNeeded $p){ & $p netcheck } }
function Ping-Test($p) {
    if(-not (Join-IfNeeded $p)){return}
    $json = & $p status --json 2>$null | Out-String
    try { $d=$json | ConvertFrom-Json } catch { Warn 'Could not parse Tailscale peer status.'; return }
    $self=@($d.Self.TailscaleIPs)
    $direct=0; $derp=0; $total=0
    foreach($peer in $d.Peer.PSObject.Properties.Value){
        $ip=@($peer.TailscaleIPs)[0]
        if(-not $ip -or $self -contains $ip){continue}
        $name=if($peer.HostName){$peer.HostName}else{$peer.DNSName}
        $total++
        Write-Host "--- $name ($ip) ---"
        $out=& $p ping --c=3 $ip 2>&1 | Out-String
        Write-Host $out
        if($out -match 'via DERP'){ $derp++ } elseif($out -match 'via .*:'){ $direct++ }
    }
    Info "Summary: $direct Direct / $derp DERP / $total peers"
}
function Status($p) {
    if(-not (Join-IfNeeded $p)){return}
    & $p status
    Write-Host "`nTailscale IPv4:"; & $p ip -4
    Write-Host "Tailscale IPv6:"; & $p ip -6
    Write-Host "`nPublic IP:"; Get-PublicIP
}
function Exit-IP($p) { if(Ensure-TS){ Info 'Current public IPs (verify again while a client is using this node as Exit Node):'; Get-PublicIP } }
function Health($p) {
    if(-not (Join-IfNeeded $p)){return}
    Info '=== Exit Node Health ==='
    $svc=Get-Service tailscaled -ErrorAction SilentlyContinue
    if($svc -and $svc.Status -eq 'Running'){Ok 'Tailscale service: active'}else{Warn 'Tailscale service: not active'}
    $router=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter
    if($router -eq 1){Ok 'IPv4 routing: enabled'}else{Warn 'IPv4 routing: disabled'}
    & $p status
    Get-PublicIP
}
function MTU-Test($p) {
    if(-not (Join-IfNeeded $p)){return}
    $target=Read-Host 'Peer Tailscale IPv4 (100.x.x.x)'
    if($target -notmatch '^100\.[0-9]+\.[0-9]+\.[0-9]+$'){Warn 'Invalid Tailscale IPv4.';return}
    foreach($size in 1472,1400,1300,1200){
        $r=ping.exe -n 2 -f -l $size $target 2>&1
        if($LASTEXITCODE -eq 0){Ok "Payload $size bytes: OK"}else{Warn "Payload $size bytes: failed"}
    }
}
function DNS-Test {
    Info '=== DNS Test ==='
    Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 | Format-Table -AutoSize
    foreach($h in 'controlplane.tailscale.com','tailscale.com'){
        try{Resolve-DnsName $h -ErrorAction Stop | Out-Null; Ok "$h resolves"}catch{Warn "$h does not resolve"}
    }
}
function Full-Benchmark($p) {
    if(-not (Join-IfNeeded $p)){return}
    Info '=== VPS Quick Benchmark ==='
    "Hostname    : $env:COMPUTERNAME"
    Get-PublicIP
    "Tailscale IPv4: $(& $p ip -4)"
    "Tailscale IPv6: $(& $p ip -6)"
    Write-Host '`nNetwork'; & $p netcheck
    Write-Host '`nPeer connectivity'; Ping-Test $p
    Write-Host '`nExit Node health'; Health $p
}
function Logout($p) {
    Warn 'This logs this Windows Server out of the Tailnet.'
    if((Read-Host 'Type YES to confirm') -eq 'YES'){& $p logout;Ok 'Device logged out.'}else{Write-Host 'Cancelled.'}
}
function Uninstall-TS($p) {
    Warn 'This removes Tailscale from this Windows Server.'
    if((Read-Host 'Type UNINSTALL to confirm') -ne 'UNINSTALL'){Write-Host 'Cancelled.';return}
    & $p logout 2>$null
    $app=Get-AppxPackage -AllUsers *Tailscale* -ErrorAction SilentlyContinue
    if($app){$app | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue}
    $pkg=Get-Package -Name *Tailscale* -ErrorAction SilentlyContinue
    if($pkg){$pkg | Uninstall-Package -Force -ErrorAction SilentlyContinue}
    Ok 'Uninstall requested. Verify Programs/Apps if the MSI remains.'
}

if(-not (Need-Admin)){exit 1}
while($true){
    Clear-Host
    Write-Host '╔══════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║       Tailscale Full Setup - Windows     ║' -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1) Install Tailscale'
    Write-Host '  2) Setup Exit Node (IPv4 + IPv6)'
    Write-Host '  3) Enable Tailscale SSH'
    Write-Host '  4) Ping / Direct-DERP Test'
    Write-Host '  5) Network Benchmark (netcheck)'
    Write-Host '  6) Show Status + Public IP'
    Write-Host '  7) Logout / Remove This Device'
    Write-Host '  8) Exit IP Test'
    Write-Host '  9) Exit Node Health Check'
    Write-Host ' 10) MTU Test'
    Write-Host ' 11) DNS Test'
    Write-Host ' 12) Full VPS Benchmark'
    Write-Host ' 13) Uninstall Tailscale'
    Write-Host '  0) Exit'
    Write-Host ''
    $c=Read-Host 'Select an option'
    $p=TailscalePath
    switch($c){
        '1'{Install-TS}
        '2'{if($p=Ensure-TS){Setup-Exit $p}}
        '3'{if($p=Ensure-TS){Setup-SSH $p}}
        '4'{if($p=Ensure-TS){Ping-Test $p}}
        '5'{if($p=Ensure-TS){Netcheck $p}}
        '6'{if($p=Ensure-TS){Status $p}}
        '7'{if($p=Ensure-TS){Logout $p}}
        '8'{Exit-IP $p}
        '9'{if($p=Ensure-TS){Health $p}}
        '10'{if($p=Ensure-TS){MTU-Test $p}}
        '11'{DNS-Test}
        '12'{if($p=Ensure-TS){Full-Benchmark $p}}
        '13'{if($p=Ensure-TS){Uninstall-TS $p}}
        '0'{break}
        default{Warn 'Invalid option.'}
    }
    if($c -eq '0'){break}
    Write-Host '';Read-Host 'Press Enter to return to menu' | Out-Null
}

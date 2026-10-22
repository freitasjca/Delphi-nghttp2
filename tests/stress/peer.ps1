# ============================================================================
#  peer.ps1 - CL5.5 STRESS-1 independent HTTP/2 peer (Windows/Delphi side).
#
#  Starts an nginx (h2c) Docker container as the independent peer for
#  Nghttp2ClientStress (stage 4t), and - the point of this file - it finds
#  Docker wherever it lives:
#
#    1. Docker on the Windows host      -> run it here, bind 127.0.0.1.
#    2. else Docker inside WSL          -> run peer.sh INSIDE WSL bound to
#       0.0.0.0, then confirm the Windows side can reach it over
#       localhost-forwarding before declaring READY. This is the common case:
#       Docker Desktop not installed, dockerd only in the WSL distro.
#    3. neither                         -> SKIP (exit 3), never a failure.
#
#  As in peer.sh there is NO committed Dockerfile and NO mounted .conf (the repo
#  normalises those to CRLF, and a stray CR breaks nginx/Docker silently): the
#  whole server is one `docker run ... sh -c <script>`, assembled with explicit
#  LF newlines (branch 1) or reused straight from peer.sh (branch 2).
#
#    powershell -ExecutionPolicy Bypass -File peer.ps1 start [PORT]
#    powershell -ExecutionPolicy Bypass -File peer.ps1 stop  [PORT]
#
#  Exit 0 = ready (start) / removed (stop); exit 3 = SKIP. run-tests.bat treats
#  exit 3 as "skip the stage loudly".
# ============================================================================
param(
  [string]$Action = 'start',
  [int]$Port = 19340
)

$ErrorActionPreference = 'SilentlyContinue'
$Name  = 'nghttp2-stress-peer'
$Image = 'nginx:1.27-alpine'

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Wsl-PeerScript {
  # WSL path of this directory's peer.sh, computed directly (no dependency on
  # `wsl wslpath`, which returned empty in the field). Maps C:\a\b -> /mnt/c/a/b.
  if (-not (Have 'wsl')) { Write-Host 'NOTE: wsl.exe not found on PATH'; return '' }
  if ($PSScriptRoot -notmatch '^[A-Za-z]:\\') {
    Write-Host "NOTE: cannot map to a WSL path: '$PSScriptRoot'"; return ''
  }
  $drive = $PSScriptRoot.Substring(0, 1).ToLower()
  $rest  = ($PSScriptRoot.Substring(2) -replace '\\', '/')
  return "/mnt/$drive$rest/peer.sh"
}

function Reachable($p) {
  # Can a Windows process open 127.0.0.1:$p? (localhost-forwarding check)
  $c = New-Object System.Net.Sockets.TcpClient
  try { $c.Connect('127.0.0.1', $p); return $c.Connected }
  catch { return $false }
  finally { $c.Close() }
}

# ---------------------------------------------------------------- stop --------
if ($Action -eq 'stop') {
  if (Have 'docker') { docker rm -f $Name 2>$null | Out-Null }
  $s = Wsl-PeerScript
  if ($s) { wsl bash -lc "'$s' stop $Port" 2>$null | Out-Null }
  exit 0
}

# ------------------------------------------------- branch 1: Windows docker ---
if (Have 'docker') {
  docker info 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    docker rm -f $Name 2>$null | Out-Null
    $lf = "`n"
    $script = @(
      'set -e',
      'head -c 4194304 /dev/zero > /usr/share/nginx/html/big.bin',
      "cat > /etc/nginx/nginx.conf <<'CONF'",
      'worker_processes 1;',
      'error_log /dev/stderr warn;',
      'events { worker_connections 1024; }',
      'http {',
      '  access_log off;',
      '  keepalive_requests 5;',
      '  server {',
      "    listen $Port;",
      '    http2 on;',
      '    root /usr/share/nginx/html;',
      "    location = /small { return 200 'ok'; }",
      '    location / { }',
      '  }',
      '}',
      'CONF',
      "exec nginx -g 'daemon off;'"
    ) -join $lf
    docker run -d --name $Name -p "127.0.0.1:${Port}:${Port}" $Image sh -c $script | Out-Null
    if ($LASTEXITCODE -eq 0) {
      # Wait until nginx actually SERVES (GET /small = 'ok'), not merely until
      # Docker's published port accepts TCP - the proxy accepts before nginx has
      # started, and a TCP-only check declared READY too early. nginx serves
      # HTTP/1.1 on this listener too, so Invoke-WebRequest suffices.
      for ($i = 0; $i -lt 100; $i++) {
        try {
          $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/small" -UseBasicParsing -TimeoutSec 2
          if ($r.Content -eq 'ok') { Write-Host "READY $Port"; exit 0 }
        } catch { }
        Start-Sleep -Milliseconds 200
      }
      Write-Host 'SKIP: Windows docker peer did not become ready'
      docker logs $Name 2>&1 | Select-Object -Last 20
      docker rm -f $Name 2>$null | Out-Null
      exit 3
    }
    Write-Host 'SKIP: Windows docker run failed (image pull or port bind)'
    exit 3
  }
}

# ---------------------------------------------- branch 2: Docker inside WSL ---
$s = Wsl-PeerScript
if ($s) {
  Write-Host "NOTE: no Windows docker; driving Docker inside WSL via $s"
  # peer.sh does its own `docker info` check inside WSL and exits 3 if absent.
  # Bind 0.0.0.0 so the published port is visible to Windows via forwarding.
  wsl bash -lc "'$s' start $Port 0.0.0.0"
  if ($LASTEXITCODE -eq 0) {
    for ($i = 0; $i -lt 50; $i++) {
      if (Reachable $Port) { Write-Host "READY $Port"; exit 0 }
      Start-Sleep -Milliseconds 200
    }
    Write-Host "SKIP: WSL peer is up but 127.0.0.1:$Port is not reachable from"
    Write-Host '      Windows (WSL localhost-forwarding off, or mirrored-mode RSTs).'
    Write-Host "      Try: Nghttp2ClientStress.exe host=<WSL-IP> peer=$Port"
    wsl bash -lc "'$s' stop $Port" 2>$null | Out-Null
    exit 3
  }
  Write-Host 'SKIP: no Docker on Windows and WSL docker is not available either'
  exit 3
}

Write-Host 'SKIP: no Docker on Windows and no WSL to fall back to'
exit 3

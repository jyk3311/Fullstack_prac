[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ProjectName,
    [string]$ComposeFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.yml'),
    [uri]$BaseUri = 'http://localhost:8080',
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(1, 30)][int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
    throw '상태 확인에 사용할 Compose 파일이 없습니다.'
}
if (-not $BaseUri.IsAbsoluteUri -or $BaseUri.Scheme -notin @('http', 'https') -or $BaseUri.UserInfo) {
    throw '인증 정보가 없는 HTTP 또는 HTTPS 기본 주소가 필요합니다.'
}

$expectedServices = @('db', 'backend', 'frontend', 'nginx')
$usersUri = $BaseUri.AbsoluteUri.TrimEnd('/') + '/api/users'
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastReason = '서비스 준비 대기'
while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    # 다른 프로젝트의 정상 컨테이너로 이번 배포를 성공 판정하지 않는다.
    try {
        $lines = @(& docker compose -p $ProjectName -f $ComposeFile ps --all --format json 2>$null)
        $dockerExit = $LASTEXITCODE
    }
    catch {
        throw 'Docker 상태 조회 명령을 실행하지 못했습니다.'
    }
    if ($dockerExit -ne 0) {
        throw ('Docker 상태 조회 실패. 종료 코드: ' + $dockerExit)
    }
    try {
        $containers = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ConvertFrom-Json -InputObject $_ })
    }
    catch {
        throw 'Docker 상태 조회 결과가 유효한 JSON이 아닙니다.'
    }
    $ready = $true
    foreach ($service in $expectedServices) {
        $rows = @($containers | Where-Object { $_.Project -eq $ProjectName -and $_.Service -eq $service })
        if ($rows.Count -eq 0) {
            throw ('대상 프로젝트의 서비스가 없습니다: ' + $service)
        }
        foreach ($row in $rows) {
            if ($row.State -in @('exited', 'dead', 'removing')) {
                throw ('서비스가 실행되지 않았습니다: ' + $service + ', 상태: ' + $row.State)
            }
            if ($row.State -ne 'running' -or ($row.Health -and $row.Health -ne 'healthy')) {
                $ready = $false
                $lastReason = '서비스 준비 중: ' + $service + ', 상태: ' + $row.State + ', health: ' + $row.Health
            }
        }
    }
    if ($ready) {
        $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        $requestTimeout = [int][Math]::Min(5, [Math]::Ceiling($remaining))
        try {
            # 고정 health 응답 대신 Nginx·서버·DB를 실제로 거치는 읽기 경로를 확인한다.
            $response = Invoke-WebRequest -UseBasicParsing -Uri $usersUri -TimeoutSec $requestTimeout -MaximumRedirection 0
            if ([int]$response.StatusCode -ne 200) {
                throw 'API가 HTTP 200을 반환하지 않았습니다.'
            }
            $content = $response.Content.Trim()
            if (-not $content.StartsWith('[') -or -not $content.EndsWith(']')) {
                throw '사용자 목록 응답이 JSON 배열이 아닙니다.'
            }
            try { $users = ConvertFrom-Json -InputObject $content }
            catch { throw '사용자 목록 응답이 유효한 JSON이 아닙니다.' }
            foreach ($user in $users) {
                if ($null -eq $user) { throw '사용자 응답 항목이 비어 있습니다.' }
                foreach ($field in @('id', 'username', 'email', 'createdAt')) {
                    if ($user.PSObject.Properties.Name -notcontains $field) {
                        throw '사용자 목록 응답의 필수 필드가 없습니다.'
                    }
                }
            }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Write-Host ('배포 확인 완료: 프로젝트 ' + $ProjectName + ', 서비스 4개 running, /api/users HTTP 200')
            return
        }
        catch {
            # 응답 본문이나 사용자 데이터를 실패 로그에 노출하지 않는다.
            $lastReason = 'API 응답 검사 실패 (' + $_.Exception.GetType().Name + ')'
        }
    }
    Write-Host $lastReason
    $sleepMilliseconds = [int][Math]::Min(
        $PollIntervalSeconds * 1000,
        [Math]::Max(0, ($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000)
    )
    if ($sleepMilliseconds -gt 0) { Start-Sleep -Milliseconds $sleepMilliseconds }
}
throw ('배포 확인 제한 시간 초과: ' + $TimeoutSeconds + '초. 마지막 상태: ' + $lastReason)
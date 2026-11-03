[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JavaHome,
    [Parameter(Mandatory = $true)][string]$CoverityBin,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Invoke-CheckedCommand {
    param([string]$Executable, [string[]]$Arguments)

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('명령 실행 실패: {0}, 종료 코드: {1}' -f [IO.Path]::GetFileName($Executable), $LASTEXITCODE)
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$backendDirectory = Join-Path $repositoryRoot 'backend'
$captureRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.coverity'))
$runDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $runDirectory.StartsWith($captureRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Capture 출력은 저장소의 .coverity 하위 경로여야 합니다.'
}

$javac = Join-Path $JavaHome 'bin/javac.exe'
$java = Join-Path $JavaHome 'bin/java.exe'
$configure = Join-Path $CoverityBin 'cov-configure.exe'
$build = Join-Path $CoverityBin 'cov-build.exe'
$manageEmit = Join-Path $CoverityBin 'cov-manage-emit.exe'
foreach ($executable in @($javac, $java, $configure, $build, $manageEmit, (Join-Path $backendDirectory 'gradlew.bat'))) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw ('필수 실행 파일을 찾을 수 없습니다: {0}' -f $executable)
    }
}

$compilerVersion = & $javac -version
if ($LASTEXITCODE -ne 0 -or "$compilerVersion" -notmatch '^javac 17(\.|$)') {
    throw ('Java 17 JDK가 필요합니다. 확인 결과: {0}' -f $compilerVersion)
}
Write-Host ('빌드 컴파일러: {0}' -f $compilerVersion)
$env:JAVA_HOME = $JavaHome
$env:Path = (Join-Path $JavaHome 'bin') + ';' + $env:Path

# 이전 결과가 섞여 빈 Capture를 성공으로 오인하지 않도록 기존 출력은 재사용하지 않는다.
New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runDirectory | Out-Null
$config = Join-Path $runDirectory 'coverity_config.xml'
$intermediateDirectory = Join-Path $runDirectory 'idir'
Invoke-CheckedCommand $configure @('--config', $config, '--java', '--no-capture-config-files')

$initScript = Join-Path $runDirectory 'capture.init.gradle'
# 이 도구 버전은 Gradle 내부 컴파일러 계측에서 실패하므로 Capture에서만 외부 javac를 사용한다.
$initContent = @(
    'allprojects {'
    '    tasks.withType(org.gradle.api.tasks.compile.JavaCompile).configureEach {'
    '        options.fork = true'
    "        options.forkOptions.executable = new File(System.getenv('JAVA_HOME'), 'bin/javac.exe').absolutePath"
    '    }'
    '}'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($initScript, $initContent, [Text.UTF8Encoding]::new($false))

Push-Location $backendDirectory
try {
    # 캐시나 기존 컴파일 결과가 사용되면 Java 컴파일을 관찰하지 못하므로 새로 빌드한다.
    Invoke-CheckedCommand $build @(
        '--config', $config,
        '--dir', $intermediateDirectory,
        '--return-emit-failures',
        'cmd.exe', '/d', '/c',
        ('gradlew.bat --init-script "{0}" --no-daemon --no-build-cache --no-configuration-cache clean bootJar -x test --stacktrace' -f $initScript)
    )
}
finally {
    Pop-Location
}

$emitJson = (Invoke-CheckedCommand $manageEmit @('--dir', $intermediateDirectory, '--java', 'list-json')) -join [Environment]::NewLine
$translationUnits = ConvertFrom-Json -InputObject $emitJson
$javaUnits = @($translationUnits | Where-Object { $_.hasASTs -eq $true -and $_.primaryFilename -match '\.java$' })
if ($javaUnits.Count -eq 0) {
    throw '분석 가능한 Java 소스가 Capture되지 않았습니다.'
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'java-translation-units.json'), $emitJson, [Text.UTF8Encoding]::new($false))
Write-Host ('Java Capture 검증 완료: {0}개 소스' -f $javaUnits.Count)
Write-Host ('중간 결과 경로: {0}' -f $intermediateDirectory)
$javaUnits | ForEach-Object { Write-Host $_.primaryFilename }

pipeline {
    agent any

    environment {
        GRADLE_USER_HOME = "${WORKSPACE}/.coverity/gradle-user-home"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Load Coverity Settings') {
            steps {
                withCredentials([file(
                    credentialsId: 'fullstack-coverity-settings',
                    variable: 'COVERITY_SETTINGS_FILE'
                )]) {
                    script {
                        def settings = readJSON file: env.COVERITY_SETTINGS_FILE, returnPojo: true
                        if (!(settings instanceof Map)) {
                            error('Coverity 실행 설정은 JSON 객체여야 합니다.')
                        }
                        ['JAVA_HOME', 'COVERITY_BIN', 'COVERITY_URL', 'COVERITY_STREAM'].each { key ->
                            if (!(settings[key] instanceof String) || settings[key].trim().isEmpty()) {
                                error("Coverity 실행 설정 누락 또는 잘못된 형식: ${key}")
                            }
                        }
                        env.JAVA_HOME = settings.JAVA_HOME
                        env.COVERITY_BIN = settings.COVERITY_BIN
                        env.COVERITY_URL = settings.COVERITY_URL
                        env.COVERITY_STREAM = settings.COVERITY_STREAM
                    }
                }
            }
        }

        stage('Check Tools') {
            steps {
                bat 'docker --version'
                bat 'docker compose version'
                bat 'git --version'
                bat 'docker info --format "{{.ServerVersion}}"'
            }
        }

        stage('Coverity Capture') {
            steps {
                powershell encoding: 'UTF-8', script: '''
                    & "$env:WORKSPACE/scripts/capture-coverity.ps1" `
                        -JavaHome $env:JAVA_HOME `
                        -CoverityBin $env:COVERITY_BIN `
                        -OutputDirectory "$env:WORKSPACE/.coverity/$env:BUILD_NUMBER"
                '''
            }
        }

        stage('Coverity Analyze') {
            steps {
                bat '"%COVERITY_BIN%/cov-analyze.exe" --dir "%WORKSPACE%/.coverity/%BUILD_NUMBER%/idir"'
            }
        }

        stage('Coverity Upload') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'coverity-connect-account',
                    usernameVariable: 'COVERITY_USER',
                    passwordVariable: 'COVERITY_PASSPHRASE'
                )]) {
                    powershell encoding: 'UTF-8', script: '''
                        $ErrorActionPreference = 'Stop'
                        if (([uri]$env:COVERITY_URL).Scheme -ne 'https') {
                            throw 'CC 업로드는 HTTPS 주소만 허용합니다.'
                        }
                        if ([string]::IsNullOrWhiteSpace($env:COVERITY_USER) -or [string]::IsNullOrEmpty($env:COVERITY_PASSPHRASE)) {
                            throw 'Jenkins에서 CC 인증 정보를 주입하지 못했습니다.'
                        }
                        $runDirectory = Join-Path $env:WORKSPACE ".coverity/$env:BUILD_NUMBER"
                        $snapshotFile = Join-Path $runDirectory 'snapshot-id.txt'
                        if (Test-Path -LiteralPath $snapshotFile) {
                            throw '이미 업로드 결과가 있어 중복 업로드를 중단합니다.'
                        }
                        $sourceVersion = if ([string]::IsNullOrWhiteSpace($env:GIT_COMMIT)) { 'local-worktree' } else { $env:GIT_COMMIT }
                        $description = 'Jenkins ' + $env:JOB_NAME + ' #' + $env:BUILD_NUMBER
                        & "$env:COVERITY_BIN/cov-commit-defects.exe" `
                            --url $env:COVERITY_URL `
                            --stream $env:COVERITY_STREAM `
                            --user $env:COVERITY_USER `
                            --on-new-cert distrust `
                            --dir (Join-Path $runDirectory 'idir') `
                            --version $sourceVersion `
                            --description $description `
                            --snapshot-id-file $snapshotFile
                        if ($LASTEXITCODE -ne 0) {
                            throw ('CC 업로드 실패. 종료 코드: ' + $LASTEXITCODE)
                        }
                        if (-not (Test-Path -LiteralPath $snapshotFile -PathType Leaf)) {
                            throw '업로드 결과의 Snapshot ID 파일이 없습니다.'
                        }
                        $snapshotId = ([IO.File]::ReadAllText($snapshotFile)).Trim()
                        if ($snapshotId -notmatch '^[0-9]+$') {
                            throw '업로드 결과의 Snapshot ID가 유효하지 않습니다.'
                        }
                        Write-Host ('COVERITY_SNAPSHOT_ID=' + $snapshotId)
                        Write-Host ('COVERITY_SOURCE_VERSION=' + $sourceVersion)
                    '''
                }
            }
        }

        stage('Build and Deploy') {
            steps {
                bat 'docker compose -p fullstack-pipeline-test down'
                bat 'docker compose -p fullstack-pipeline-test up -d --build'
            }
        }

        stage('Check Containers') {
            steps {
                timeout(time: 3, unit: 'MINUTES') {
                    powershell encoding: 'UTF-8', script: '''
                        & "$env:WORKSPACE/scripts/wait-for-deployment.ps1" -ProjectName 'fullstack-pipeline-test'
                    '''
                }
            }
        }
    }

    post {
        success {
            echo '배포가 완료되었습니다.'
        }
        failure {
            echo '파이프라인이 실패했습니다. 실패한 단계를 확인하세요.'
        }
    }
}

pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Check Tools') {
            steps {
                sh '''
                    docker --version
                    docker compose version
                    git --version
                '''
            }
        }

        stage('Build and Deploy') {
            steps {
                sh '''
                    docker compose down
                    docker compose up -d --build
                '''
            }
        }

        stage('Check Containers') {
            steps {
                sh '''
                    docker ps
                '''
            }
        }
    }

    post {
        success {
            echo 'Deployment succeeded.'
        }
        failure {
            echo 'Deployment failed.'
        }
    }
}

pipeline {
    agent any

    environment {
        ANSIBLE_DIR = "ansible"
        IMAGE_NAME = "ic-webapp"
        DOCKERHUB_ID = "azeriock"
        DOCKERHUB_PASSWORD = credentials('dockerhub_password')
        ANSIBLE_IMAGE_AGENT = "registry.gitlab.com/robconnolly/docker-ansible:latest"
    }
    stages{
        stage('Checkout') {
            steps {
                echo "Clonage du dépôt"
                checkout scm
            }
        }

        stage('Build Docker Images') {
            steps {
                sh '''
                docker build --no-cache -f ./app/Dockerfile -t ${DOCKERHUB_ID}/${IMAGE_NAME} ./app
                '''
            }
        }

        stage('Scan Image with  SNYK') {
            environment{
                SNYK_TOKEN = credentials('snyk_token')
            }
            steps {
                script{
                    sh '''
                        echo "Starting Image scan ${DOCKERHUB_ID}/${IMAGE_NAME} ..."
                        echo There is Scan result :
                        SCAN_RESULT=$(docker run --rm -e SNYK_TOKEN=$SNYK_TOKEN -v /var/run/docker.sock:/var/run/docker.sock -v $(pwd):/app snyk/snyk:docker snyk test --docker $DOCKERHUB_ID/${IMAGE_NAME} --json ||  if [[ $? -gt "1" ]];then echo -e "Warning, you must see scan result \n" ;  false; elif [[ $? -eq "0" ]]; then   echo "PASS : Nothing to Do"; elif [[ $? -eq "1" ]]; then   echo "Warning, passing with something to do";  else false; fi)
                        echo "Scan ended"
                        '''
                    }
                }
        }

        stage('Test technique du conteneur') {
            steps {
                echo "Lancement des conteneurs pour tests"
                    sh '''
                        # Nettoyage préalable
                        docker ps -a | grep -i test_icwebapp && docker rm -f test_icwebapp

                        docker run -d --name test_icwebapp -p 8090:8080 ${DOCKERHUB_ID}/${IMAGE_NAME}

                        echo "Attente du démarrage des services..."
                        timeout 60 bash -c 'until curl -f http://localhost:8090 >/dev/null 2>&1; do sleep 3; done'

                        echo "Le service semble accessibles."
                    '''
            }
        }

        stage('Cleanup before Ansible tests') {
            steps {
                script {
                     sh '''
                        docker stop test_icwebapp
                        docker rm test_icwebapp
                    '''
                }
            }
        }

        stage('Push to Registry') {
            steps {
                echo " Push des images vers le registre Docker"
                script {
                sh '''
                    echo $DOCKERHUB_PASSWORD | docker login -u $DOCKERHUB_ID --password-stdin
                    docker push ${DOCKERHUB_ID}/${IMAGE_NAME}
                '''
                }
            }
        }
            
        stage ('Prepare ansible environment') {
            agent any
            environment {
                VAULT_KEY = credentials('vault_key')
            }        
            steps {
                script {
                sh '''
                    echo $VAULT_KEY > vault.key
                '''
                }
            }
        }

        stage('Déploiement via Ansible') {
            agent{
                docker { 
                    image 'registry.gitlab.com/robconnolly/docker-ansible:latest'
                }
            }
            stages {
                stage ("Check all playbook syntax") {
                    steps {
                        script {
                            sh '''
                                export ANSIBLE_CONFIG=$(pwd)/ansible/ansible.cfg
                                ansible-lint -x 306 ansible/playbooks/* || echo passing linter                                     
                            '''
                        }
                    }
                }
                stage ("Install sshpass") {
                    steps {
                        script {
                            sh '''
                                apt update -y
                                apt install sshpass -y
                            '''
                        }
                    }
                }
                stage ("PRODUCTION - Install docker") {
                    steps {
                        script {
                            sh '''
                                export ANSIBLE_CONFIG=$(pwd)/ansible/ansible.cfg
                                ansible-playbook ansible/playbooks/install-docker.yml --vault-password-file vault.key -l odoo_server,pg_admin_server
                            '''
                        }
                    }
                }
                stage ("PRODUCTION - Deploy pgadmin") {
                    steps {
                        script {
                            sh '''
                                export ANSIBLE_CONFIG=$(pwd)/ansible/ansible.cfg
                                ansible-playbook ansible/playbooks/deploy-pgadmin.yml --vault-password-file vault.key  -l pg_admin -vvv
                            '''
                        }
                    }
                }
                stage ("PRODUCTION - Deploy ic-webapp") {
                    steps {
                        script {
                            sh '''
                                export ANSIBLE_CONFIG=$(pwd)/ansible/ansible.cfg
                                ansible-playbook ansible/playbooks/deploy-ic_webapp.yml --vault-password-file vault.key  -l ic_webapp
                            '''
                        }
                    }
                }
                stage ("PRODUCTION - Deploy odoo") {
                    steps {
                        script {
                            sh '''
                                export ANSIBLE_CONFIG=$(pwd)/ansible/ansible.cfg
                                ansible-playbook ansible/playbooks/deploy-odoo.yml --vault-password-file vault.key  -l odoo
                            '''
                        }
                    }
                }
            }
        }
    }  
}

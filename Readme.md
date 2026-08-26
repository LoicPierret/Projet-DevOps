[![CI - Build, Scan, Test and Push Docker Image](https://github.com/Azeriock/Projet-DevOps/actions/workflows/ci.yml/badge.svg)](https://github.com/Azeriock/Projet-DevOps/actions/workflows/ci.yml)
[![CD - Deploy to EKS](https://github.com/Azeriock/Projet-DevOps/actions/workflows/deploy.yml/badge.svg)](https://github.com/Azeriock/Projet-DevOps/actions/workflows/deploy.yml)

# 🌐 Hybrid DevOps Project: Cloud-Native (AWS EKS) & On-Premise

## 📝 Présentation du Projet
Ce projet démontre une maîtrise complète du cycle de vie DevOps à travers une approche **hybride**. Il permet de déployer la même stack applicative (ERP Odoo v17 + PostgreSQL + WebApp: ic-webapp et pgadmin) sur deux environnements radicalement différents :

1.  **Option A (Cloud-Native) :** Une infrastructure immuable, scalable et managée sur **AWS EKS**, pilotée par Terraform et GitHub Actions.
2.  **Option B (On-Premise) :** Une infrastructure traditionnelle sur serveurs Linux, configurée et maintenue via **Ansible** et **Jenkins**.

L'objectif est de prouver la capacité à gérer la transition d'une infrastructure Legacy vers le Cloud, tout en maintenant des standards de sécurité élevés (Snyk, Vault, OIDC).

---

## ☁️ Option A : Configuration Cloud-Native (AWS)

Cette configuration vise la **haute disponibilité** et l'autoscaling.

### 🏗️ Infrastructure (Terraform)
L'infrastructure est entièrement définie en code (IaC) :
* **Réseau :** VPC dédié, découpage sous-réseaux publics/privés, NAT Gateway pour la sortie sécurisée.
* **Cluster EKS :** Control Plane managé et Node Groups en Auto-Scaling (ASG) pour absorber la charge.
* **Load Balancing :** AWS Application Load Balancer (ALB) géré dynamiquement par le contrôleur Ingress Kubernetes.
* **Données :** Base de données **Amazon RDS PostgreSQL** (séparée du cluster pour la persistance) et stockage EBS pour les fichiers Odoo.
* **DNS :** Gestion DNS via Route 53 (`nuages.click`).

### 🔄 Pipeline CI/CD (GitHub Actions)
Le pipeline Cloud utilise l'authentification moderne **OpenID Connect (OIDC)** pour supprimer le besoin de clés d'accès longue durée.

1.  **Continuous Integration (`ci.yml`) :**
    * Build Docker.
    * **Scan de sécurité Snyk** de l'image.
    * Tests de santé du conteneur.
    * Push vers Docker Hub.
2.  **Continuous Deployment (`deploy.yml`) :**
    * Authentification AWS via rôle IAM (OIDC).
    * **Terraform Apply :** Mise à jour de l'infrastructure sous-jacente.
    * **Kubectl / Kustomize :** Déploiement des manifestes Kubernetes (Deployments, Services, Ingress).

---

## 🏢 Option B : Configuration On-Premise

Cette configuration simule un déploiement sur des serveurs physiques ou des VMs classiques (Bare Metal).

### ⚙️ Gestion de Configuration (Ansible)
L'état des serveurs est standardisé via des rôles Ansible précis :
* **`install-docker.yml`** : Provisionning du socle technique. Installation de Python3, pip, et du moteur Docker sur les nœuds vierges.
* **`deploy-pgadmin.yml` / `deploy-odoo.yml`** : Orchestration des conteneurs applicatifs et de la base de données sur les hôtes cibles via les modules Docker d'Ansible.
* **`deploy-ic_webapp.yml`** : Déploiement continu de l'application web personnalisée.

### 🔄 Pipeline CI/CD (Jenkins)
Le pipeline Jenkins orchestre le déploiement de bout en bout avec une isolation via agents Docker.

1.  **Build & Scan :** Construction de l'image et analyse des vulnérabilités critiques via Snyk. Si une faille est détectée, le pipeline s'arrête.
2.  **Test Technique :** Lancement éphémère du conteneur et vérification de la disponibilité HTTP (Healthcheck sur port 8090) avant toute mise en prod.
3.  **Push Registry :** Envoi vers Docker Hub uniquement si les tests passent.
4.  **Déploiement Sécurisé :**
    * Injection des secrets via **Ansible Vault** (déchiffrement à la volée avec `vault.key`).
    * Exécution des playbooks Ansible limités aux groupes d'hôtes concernés (`-l odoo`, `-l pg_admin`).

---

## 🛡️ Sécurité
Quel que soit l'environnement, la sécurité est au cœur du projet :
* **Scan de Vulnérabilités :** Intégration de **Snyk** dans les deux pipelines (GitHub & Jenkins) pour bloquer le code non sécurisé.
* **Gestion des Secrets :**
    * *Cloud :* GitHub Secrets.
    * *On-Prem :* Ansible Vault pour chiffrer les variables sensibles dans le repo git.
* **Isolation :** Les builds tournent dans des conteneurs éphémères pour ne pas polluer les environnements de build.





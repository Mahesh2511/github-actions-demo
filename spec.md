# SkillPulse EKS CI/CD Specification (MySQL in Kubernetes)

## 1. Objective

Migrate SkillPulse from Docker Compose (EC2) to Kubernetes on AWS EKS with full CI/CD using GitHub Actions.

EKS spin up script is under "/terraform/k8" using the same EKS provisioned.

This system will:
- Build and push Docker images to Docker Hub
- Deploy automatically to EKS
- Run MySQL inside Kubernetes using StatefulSet
- Support rolling deployments with zero downtime

---

## 2. Target Architecture

Internet  
↓  
AWS ALB (Ingress)  
↓  
Kubernetes Ingress Controller  
↓  
Frontend (Nginx - Deployment)  
↓  
Backend (Go API - Deployment)  
↓  
MySQL (StatefulSet + PVC)  

---

## 3. Core Components

- Kubernetes cluster (EKS)
- GitHub Actions (CI/CD)
- Docker Hub (image registry)
- Kubernetes manifests (YAML)

---

## 4. Kubernetes Resource Structure

k8s/
 ├── namespace.yml
 ├── configmap.yml
 ├── secrets.yml
 ├── backend/
 │    ├── deployment.yml
 │    ├── service.yml
 ├── frontend/
 │    ├── deployment.yml
 │    ├── service.yml
 ├── mysql/
 │    ├── statefulset.yml
 │    ├── service.yml
 │    ├── pvc.yml
 ├── ingress.yml

---

## 5. Container Images

Format:

{DOCKERHUB_USERNAME}/skillpulse-backend:<commit-sha>  
{DOCKERHUB_USERNAME}/skillpulse-frontend:<commit-sha>  

---

## 6. CI Pipeline (Build & Push)

File: .github/workflows/ci.yml

Trigger:
- Manual trigger

Steps:
1. Checkout code
2. Build backend image
3. Build frontend image
4. Tag using commit SHA
5. Push to Docker Hub

---

## 7. CD Pipeline (Deploy to EKS)

File: .github/workflows/cd-eks.yml

Trigger:
- On CI success OR manual dispatch

---

### 7.1 Configure AWS

Use GitHub Secrets:
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- AWS_REGION=ap-south-1

---

### 7.2 Update kubeconfig

aws eks update-kubeconfig \
  --region ap-south-1 \
  --name demo-eks-webapp-v25

---

### 7.3 Deploy Base Resources

kubectl apply -f k8s/namespace.yml  
kubectl apply -f k8s/configmap.yml  
kubectl apply -f k8s/secrets.yml  

---

### 7.4 Deploy MySQL First

kubectl apply -f k8s/mysql/  

Wait until MySQL pod is ready:

kubectl rollout status statefulset/mysql  

---

### 7.5 Deploy Backend and Frontend

kubectl apply -f k8s/backend/  
kubectl apply -f k8s/frontend/  
kubectl apply -f k8s/ingress.yml  

---

### 7.6 Update Images Dynamically

kubectl set image deployment/backend \
backend={DOCKERHUB_USERNAME}/skillpulse-backend:${{ github.sha }}

kubectl set image deployment/frontend \
frontend={DOCKERHUB_USERNAME}/skillpulse-frontend:${{ github.sha }}

---

### 7.7 Verify Rollout

kubectl rollout status deployment/backend  
kubectl rollout status deployment/frontend  

---

## 8. MySQL Deployment (Critical)

### Type
- StatefulSet (not Deployment)

### Storage
- Persistent Volume Claim (PVC)
- Storage class: gp2 / gp3

### Environment Variables
  
MYSQL_ROOT_PASSWORD=rootpassword123
DB_USER=skillpulse
DB_PASSWORD=skillpulse123
DB_NAME=skillpulse

### Service

- ClusterIP (mysql)
- Port: 3306

---

### 8.1 MySQL Initialization

- Use init.sql from repo
- Mount via ConfigMap or volume

---

## 9. Backend Configuration

- Replicas: 2
- Port: 8080

Environment:

DB_HOST=db
DB_PORT=3306  
DB_USER=skillpulse
DB_PASSWORD=skillpulse123
DB_NAME=skillpulse  

---

### Probes

- Liveness: /health  
- Readiness: /health  

---

## 10. Frontend Configuration

- Nginx container
- Port: 80
- Calls backend via service name

---

## 11. Services

| Component | Type       | Port |
|----------|-----------|------|
| backend  | ClusterIP | 8080 |
| frontend | ClusterIP | 80   |
| mysql    | ClusterIP | 3306 |

---

## 12. Ingress (ALB)

- AWS ALB Ingress Controller required

Routing:

/ → frontend  
/api → backend  

---

## 13. Secrets & Config

### Kubernetes Secrets

- DB credentials
- Stored as base64

### ConfigMap

- App configs
- MySQL init.sql

---

## 14. Terraform Requirements

check existing script for spining up EKS and made chnages accorimng to requirement

path : terraform/k8

---

## 15. Deployment Order (Important)

1. Namespace  
2. Secrets & ConfigMap  
3. MySQL (StatefulSet)  
4. Backend  
5. Frontend  
6. Ingress  

---

## 16. Rollback

kubectl rollout undo deployment/backend  
kubectl rollout undo deployment/frontend  

---

## 17. Risks

- MySQL pod restart → potential downtime  
- PVC misconfiguration → data loss  
- No backup strategy → high risk  
- No autoscaling → limited scalability  
- ALB misconfig → no external access  

---

## 18. Success Criteria

- CI builds and pushes images
- CD deploys to EKS automatically
- MySQL persists data via PVC
- App accessible via ALB
- Rolling updates without downtime

---

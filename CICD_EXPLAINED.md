# CI/CD Pipeline — Complete Explanation

This document explains the entire CI/CD pipeline for SkillPulse from scratch.
No prior DevOps experience assumed.

---

## Table of Contents

1. [What is CI/CD?](#1-what-is-cicd)
2. [Project Overview](#2-project-overview)
3. [How the Pieces Connect](#3-how-the-pieces-connect)
4. [Infrastructure — AWS EKS](#4-infrastructure--aws-eks)
5. [CI Workflow — Building Docker Images](#5-ci-workflow--building-docker-images)
6. [CD Workflow — Deploying to Kubernetes](#6-cd-workflow--deploying-to-kubernetes)
7. [EKS Provision Workflow — Creating the Cluster](#7-eks-provision-workflow--creating-the-cluster)
8. [Kubernetes Manifests Explained](#8-kubernetes-manifests-explained)
9. [Docker Images and Tags](#9-docker-images-and-tags)
10. [GitHub Secrets](#10-github-secrets)
11. [End-to-End Flow — What Happens When You Push Code](#11-end-to-end-flow--what-happens-when-you-push-code)
12. [Common Troubleshooting](#12-common-troubleshooting)

---

## 1. What is CI/CD?

**CI = Continuous Integration**
Every time code changes, it is automatically built and tested. In this project, CI builds Docker images and pushes them to Docker Hub.

**CD = Continuous Delivery/Deployment**
Once CI succeeds, the new version is automatically deployed to production (EKS). No manual SSH, no manual `docker pull` — it all happens automatically.

**Why bother?**
- Without CI/CD: developer changes code → manually SSHes into server → manually pulls image → manually restarts service → hopes it works
- With CI/CD: developer pushes code → everything else is automatic in 5–8 minutes

---

## 2. Project Overview

SkillPulse is a **three-tier web application**:

```
User's Browser
      ↓ HTTP
AWS ALB (Load Balancer) — public internet-facing
      ↓
Kubernetes Ingress Controller
      ├── /          → Frontend (Nginx serving HTML/CSS/JS)
      ├── /api/*     → Backend (Go REST API on port 8080)
      └── /health    → Backend health check
                            ↓
                       MySQL Database
                    (StatefulSet + EBS volume)
```

| Layer    | Technology        | Purpose                              |
|----------|-------------------|--------------------------------------|
| Frontend | Nginx + HTML/JS   | UI served as static files            |
| Backend  | Go + Gin          | REST API, business logic             |
| Database | MySQL 8.4         | Persistent data storage              |
| Platform | AWS EKS           | Managed Kubernetes cluster           |
| Infra    | Terraform         | Creates AWS resources automatically  |
| CI/CD    | GitHub Actions    | Automates build and deploy           |
| Registry | Docker Hub        | Stores Docker images                 |

---

## 3. How the Pieces Connect

```
Developer pushes code to GitHub
          │
          ▼
  GitHub Actions: CI Workflow
  - Builds backend Docker image
  - Builds frontend Docker image
  - Pushes both to Docker Hub
          │
          ▼ (triggers automatically on CI success)
  GitHub Actions: CD Workflow
  - Connects to AWS EKS cluster
  - Installs/updates ALB Ingress Controller
  - Applies all Kubernetes manifests
  - Updates running pods with new image
          │
          ▼
  App is live at ALB URL
  http://<alb-hostname>.ap-south-1.elb.amazonaws.com
```

The **EKS cluster** itself is created separately via a third workflow (Terraform). You only run that when spinning up or tearing down the cluster.

---

## 4. Infrastructure — AWS EKS

EKS is **Elastic Kubernetes Service** — AWS manages the Kubernetes control plane (the brain of the cluster). You only manage the worker nodes.

### What Terraform Creates (`terraform/k8/`)

```
AWS Account (ap-south-1 / Mumbai)
│
├── VPC: 10.0.0.0/16
│   ├── Public Subnets: 10.0.1.0/24, 10.0.2.0/24  (ALB lives here)
│   └── Private Subnets: 10.0.3.0/24, 10.0.4.0/24 (worker nodes live here)
│
├── EKS Cluster: demo-eks-webapp-v25 (Kubernetes 1.33)
│   └── Node Group: 2x EC2 instances (t3.small or t3.medium)
│       └── IAM Policy: AmazonEBSCSIDriverPolicy (so nodes can create EBS volumes)
│
├── EKS Addon: aws-ebs-csi-driver
│   └── Allows Kubernetes to provision EBS volumes for MySQL storage
│
├── IAM Role: aws-load-balancer-controller-eks
│   └── Allows the ALB Ingress Controller to create/manage AWS Load Balancers
│
└── S3 Remote State: my-terraform-state-eks-demo
    └── Stores Terraform state so team members share the same state
```

### Why Private Subnets for Nodes?

Worker nodes (EC2) sit in private subnets — they have no direct internet access. This is a security best practice. They reach the internet through a NAT Gateway. The ALB (load balancer) sits in public subnets and forwards traffic inward to the nodes.

### EBS CSI Driver

EKS 1.23+ removed the built-in ability to create EBS volumes. The `aws-ebs-csi-driver` addon adds this back. Without it, MySQL's PersistentVolumeClaim would stay `Pending` forever — the pod would never start.

### ALB Ingress Controller

This is a Kubernetes controller (installed via Helm in CD) that watches for `Ingress` resources and creates/manages an AWS Application Load Balancer automatically. When you apply `k8s/ingress.yml`, the controller reads it and creates a real ALB in your AWS account within ~2 minutes.

---

## 5. CI Workflow — Building Docker Images

**File:** `.github/workflows/ci.yml`
**Trigger:** Manual (`workflow_dispatch`) — you click "Run workflow" in GitHub Actions

### What it does, step by step

```
Step 1: Checkout Code
  └── Downloads the repo code onto the GitHub Actions runner (temporary Ubuntu VM)

Step 2: Login to Docker Hub
  └── Uses DOCKERHUB_USERNAME + DOCKERHUB_TOKEN secrets to authenticate

Step 3: Build and push Backend image
  └── Runs: docker build -t <username>/skillpulse-backend:<SHA> ./backend
  └── Pushes two tags:
        skillpulse-backend:<commit-sha>   ← immutable, e.g. abc1234
        skillpulse-backend:latest         ← always points to newest

Step 4: Build and push Frontend image
  └── Runs: docker build -f ./frontend/Dockerfile -t <username>/skillpulse-frontend:<SHA> .
  └── Pushes two tags:
        skillpulse-frontend:<commit-sha>
        skillpulse-frontend:latest
```

### Why two tags per image?

| Tag | Purpose |
|-----|---------|
| `latest` | Convenience — manual kubectl apply without CD uses this |
| `abc1234` (commit SHA) | Immutable — CD deploys this exact build; enables rollback |

### Dockerfiles

**Backend** (`backend/Dockerfile`) — multi-stage build:
```
Stage 1: golang:1.26-alpine
  └── go mod download
  └── go build → produces binary: /app/skillpulse

Stage 2: alpine (tiny runtime image)
  └── Copies only the binary from Stage 1
  └── Final image is ~15MB instead of ~500MB
```

**Frontend** (`frontend/Dockerfile`):
```
FROM nginx:alpine
  └── Copies frontend/ HTML/CSS/JS into Nginx's web root
  └── Copies nginx/nginx.conf (proxy rules to backend)
  └── Nginx serves static files and proxies /api/* to backend
```

---

## 6. CD Workflow — Deploying to Kubernetes

**File:** `.github/workflows/cd-eks.yml`
**Trigger:** Automatically when CI workflow succeeds, OR manual dispatch

### What it does, step by step

```
Step 1: Checkout Code
  └── Gets fresh copy of k8s/ manifests and workflows

Step 2: Configure AWS Credentials
  └── Uses AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY secrets
  └── GitHub Actions runner now has permission to talk to AWS

Step 3: Update kubeconfig
  └── Runs: aws eks update-kubeconfig --name demo-eks-webapp-v25
  └── Downloads credentials so kubectl can talk to the EKS cluster
  └── Without this, kubectl would have no idea where the cluster is

Step 4: Install AWS Load Balancer Controller (Helm)
  └── Helm is a Kubernetes package manager (like apt/yum but for k8s)
  └── helm upgrade --install → installs if not present, upgrades if already installed
  └── Sets the IAM role annotation so the controller can create ALBs in AWS
  └── --wait --timeout 3m → waits until controller pods are Running

Step 5: Delete stale webhook certificates
  └── WHY: ALB controller registers admission webhooks (Kubernetes calls these
           before creating services/ingresses to validate them)
  └── When the controller is reinstalled, old TLS certificates become invalid
  └── Result: "x509: certificate signed by unknown authority" error
  └── FIX: Delete old webhook configs + restart controller so it regenerates certs
  └── Commands:
        kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook
        kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook
        kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system

Step 6: Substitute image placeholder
  └── The deployment YAMLs in git contain literal: DOCKERHUB_USERNAME
  └── sed replaces it with the actual username from secrets
  └── Example: DOCKERHUB_USERNAME/skillpulse-backend → mahesh123/skillpulse-backend

Step 7: Deploy base resources (in order — order matters!)
  └── kubectl apply -f k8s/namespace.yml    → creates 'skillpulse' namespace
  └── kubectl apply -f k8s/configmap.yml    → DB config + init.sql script
  └── kubectl apply -f k8s/secrets.yml      → DB credentials (base64 encoded)

Step 8: Deploy MySQL
  └── kubectl apply -f k8s/mysql/           → applies pvc.yml + statefulset.yml + service.yml
  └── kubectl rollout status statefulset/mysql --timeout=300s
      └── WAITS up to 5 minutes for MySQL to be Ready before continuing
      └── If MySQL isn't ready, backend would crash on startup (no DB connection)

Step 9: Deploy Backend, Frontend, Ingress
  └── kubectl apply -f k8s/backend/         → deployment + service
  └── kubectl apply -f k8s/frontend/        → deployment + service
  └── kubectl apply -f k8s/ingress.yml      → ALB ingress rules

Step 10: Pin exact image SHA
  └── kubectl set image deployment/backend backend=<user>/skillpulse-backend:<SHA>
  └── kubectl set image deployment/frontend frontend=<user>/skillpulse-frontend:<SHA>
  └── This triggers a rolling update — Kubernetes replaces pods one at a time
  └── With replicas=2: pod 1 replaced → healthy → pod 2 replaced → done

Step 11: Verify rollout
  └── kubectl rollout status deployment/backend --timeout=300s
  └── kubectl rollout status deployment/frontend --timeout=300s
  └── If new pods crash (bad image, crash loop), this step FAILS → CD fails → you're alerted

Step 12: Print ALB URL
  └── Waits 30s for ALB to provision in AWS
  └── kubectl get ingress skillpulse-ingress → shows the hostname
```

### Why is the deployment order important?

```
namespace → MUST be first (everything lives inside it)
    ↓
configmap + secrets → MUST be before MySQL (MySQL reads DB name/user from these)
    ↓
MySQL → MUST be before backend (backend tries to connect on startup)
    ↓
backend + frontend + ingress → can be applied together
```

If you applied backend before MySQL, the backend pods would crash with "connection refused" and enter CrashLoopBackOff.

### Rolling Update — Zero Downtime Deploys

With `replicas: 2`, Kubernetes updates one pod at a time:

```
Before:  [backend-pod-1: v1] [backend-pod-2: v1]   ← both serving traffic
         
Phase 1: [backend-pod-1: v2] [backend-pod-2: v1]   ← pod-1 updating, pod-2 still serving
         
After:   [backend-pod-1: v2] [backend-pod-2: v2]   ← both running new version
```

Users never see downtime during a deploy.

---

## 7. EKS Provision Workflow — Creating the Cluster

**File:** `.github/workflows/EKS_deployment.yaml`
**Trigger:** Manual — you choose action: `apply` or `destroy`

This runs `terraform apply` or `terraform destroy` in `terraform/k8/`.

### Terraform Remote State

Terraform stores its state (what it created) in an S3 bucket, not locally. This means:
- Multiple team members can run Terraform without conflicts
- If your laptop breaks, state is not lost
- DynamoDB table (`terraform-lock`) prevents two people running `terraform apply` simultaneously

### First-time setup (one-time manual steps)

Before running the workflow, you must create these manually:
```bash
# S3 bucket for state
aws s3 mb s3://my-terraform-state-eks-demo --region ap-south-1

# DynamoDB table for locking
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

### apply vs destroy

| Action | What happens | Time |
|--------|-------------|------|
| `apply` | Creates entire cluster, VPC, IAM roles | ~12 min |
| `destroy` | Deletes everything — cluster, VPC, IAM roles | ~10 min |

**Warning:** `destroy` deletes all Kubernetes workloads and the MySQL EBS volume. All data is lost.

---

## 8. Kubernetes Manifests Explained

All Kubernetes config lives in `k8s/`. Kubernetes reads these YAML files and makes the described state real.

### namespace.yml
```yaml
kind: Namespace
metadata:
  name: skillpulse
```
A namespace is like a folder — all SkillPulse resources live inside `skillpulse` namespace, isolated from other apps on the same cluster.

### configmap.yml
Stores non-secret configuration as key-value pairs. Used to:
- Pass `DB_HOST=mysql`, `DB_PORT=3306`, `DB_NAME=skillpulse` to the backend
- Store the `init.sql` script that creates the database schema on first MySQL startup

ConfigMap values are visible in plain text — never put passwords here.

### secrets.yml
Like ConfigMap but base64-encoded (not encrypted — just encoded). Used for:
- `MYSQL_ROOT_PASSWORD`
- `DB_PASSWORD`

Kubernetes stores secrets separately from other resources for access control purposes.

To encode a value: `echo -n "mypassword" | base64`
To decode: `echo "bXlwYXNzd29yZA==" | base64 -d`

### mysql/statefulset.yml
A StatefulSet is used instead of a regular Deployment because MySQL needs:
- **Stable pod name** (`mysql-0`, not random) — backend connects to `mysql` hostname
- **Persistent storage** — data must survive pod restarts

The StatefulSet mounts two volumes:
- PVC at `/var/lib/mysql` — MySQL data files
- ConfigMap at `/docker-entrypoint-initdb.d/` — MySQL runs `init.sql` on first boot to create tables

### mysql/pvc.yml (PersistentVolumeClaim)
Requests a 5GB EBS volume from AWS. The EBS CSI driver fulfills this request by creating a real EBS volume in your AWS account and attaching it to the node running MySQL.

```
PVC (request) → StorageClass (gp2) → EBS CSI driver → Real EBS volume in AWS
```

### backend/deployment.yml + frontend/deployment.yml
A Deployment manages stateless pods. Key settings:
- `replicas: 2` — always keep 2 pods running
- `image: DOCKERHUB_USERNAME/skillpulse-backend:latest` — placeholder replaced by CD
- `livenessProbe` — if this fails, Kubernetes restarts the pod
- `readinessProbe` — if this fails, Kubernetes stops sending traffic to the pod

Difference between liveness and readiness:
- **Liveness:** "Is the pod alive?" → restart if no
- **Readiness:** "Is the pod ready to serve traffic?" → remove from load balancer if no

### ingress.yml
Tells the ALB Ingress Controller what routing rules to apply to the AWS ALB:

```
/        → frontend service (port 80)
/api/*   → backend service (port 8080)
/health  → backend service (port 8080)
```

Key annotations:
- `kubernetes.io/ingress.class: alb` — use ALB controller
- `alb.ingress.kubernetes.io/scheme: internet-facing` — create public ALB
- `alb.ingress.kubernetes.io/target-type: ip` — route directly to pod IPs (not node ports)

---

## 9. Docker Images and Tags

Images are stored on Docker Hub at:
- `<DOCKERHUB_USERNAME>/skillpulse-backend`
- `<DOCKERHUB_USERNAME>/skillpulse-frontend`

### Tag strategy

| Tag | Example | Meaning |
|-----|---------|---------|
| `latest` | `skillpulse-backend:latest` | Newest build |
| commit SHA | `skillpulse-backend:abc1234` | Exact build from that commit |

CD always deploys the commit SHA tag — `latest` is just a convenience pointer.

### Why Docker Hub and not ECR?

Docker Hub is free for public images and requires no AWS setup. ECR (AWS Elastic Container Registry) would require additional IAM permissions and an ECR repository. For this project, Docker Hub keeps it simple.

---

## 10. GitHub Secrets

Secrets are encrypted values stored in GitHub → Settings → Secrets → Actions. Workflows reference them as `${{ secrets.SECRET_NAME }}`.

| Secret | Where it's used | What it is |
|--------|----------------|-----------|
| `DOCKERHUB_USERNAME` | CI + CD | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | CI | Docker Hub access token (not password) |
| `AWS_ACCESS_KEY_ID` | CD (EKS), EKS provision | AWS IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | CD (EKS), EKS provision | AWS IAM user secret key |
| `HOST` | CD (EC2) | EC2 instance IP (legacy) |
| `EC2_USER` | CD (EC2) | SSH username (legacy) |
| `EC2_SSH_KEY` | CD (EC2) | SSH private key (legacy) |

**Never put secrets in code.** If a secret is committed to git, rotate it immediately — git history is public and permanent.

---

## 11. End-to-End Flow — What Happens When You Push Code

### Full automated flow

```
1. Developer runs:
   GitHub Actions → TWS CI Workflow → Run workflow

2. CI Workflow starts (ubuntu-latest runner):
   - Checks out code
   - Logs into Docker Hub
   - Builds backend image: docker build ./backend
   - Pushes: skillpulse-backend:abc1234 + skillpulse-backend:latest
   - Builds frontend image: docker build -f ./frontend/Dockerfile .
   - Pushes: skillpulse-frontend:abc1234 + skillpulse-frontend:latest
   - Duration: ~3-4 minutes

3. CI succeeds → CD Workflow triggers automatically

4. CD Workflow starts (fresh ubuntu-latest runner):
   - Configures AWS credentials
   - Gets kubeconfig for demo-eks-webapp-v25
   - helm upgrade --install aws-load-balancer-controller
   - Deletes stale webhook certs, restarts controller
   - sed replaces DOCKERHUB_USERNAME in deployment YAMLs
   - kubectl apply namespace + configmap + secrets
   - kubectl apply mysql/ → waits until MySQL pod is Running+Ready
   - kubectl apply backend/ frontend/ ingress.yml
   - kubectl set image → updates both deployments to commit SHA
   - Rolling update: old pods replaced one at a time
   - kubectl rollout status → confirms all pods healthy
   - Prints ALB URL
   - Duration: ~4-5 minutes

5. App is live. Total time from trigger to live: ~8-9 minutes
```

### Manual redeploy (if needed)

```
GitHub Actions → TWS CD EKS Workflow → Run workflow
  └── image_tag: enter a commit SHA or leave blank for 'latest'
```

### Checking what's running

```powershell
# All resources in skillpulse namespace
kubectl get all -n skillpulse

# Watch pods in real time
kubectl get pods -n skillpulse -w

# Get the ALB URL
kubectl get ingress skillpulse-ingress -n skillpulse

# Logs
kubectl logs deployment/backend -n skillpulse
kubectl logs deployment/frontend -n skillpulse
kubectl logs statefulset/mysql -n skillpulse

# Rollback backend to previous version
kubectl rollout undo deployment/backend -n skillpulse
```

---

## 12. Common Troubleshooting

### Pod stuck in `Pending`

```bash
kubectl describe pod <pod-name> -n skillpulse
```
Look at the `Events` section at the bottom.

- **"0/2 nodes available: pod has unbound immediate PersistentVolumeClaims"** → EBS CSI driver not installed
- **"Insufficient cpu/memory"** → Node group is full, scale up or reduce replicas
- **"did not have node to schedule"** → Same as above

### Pod in `CrashLoopBackOff`

```bash
kubectl logs <pod-name> -n skillpulse --previous
```
The `--previous` flag shows logs from the crashed container. Common causes:
- Backend can't connect to MySQL (check MySQL is Running first)
- Wrong environment variable (check ConfigMap/Secret values)
- App bug causing startup crash

### ALB URL shows no ADDRESS

```bash
kubectl describe ingress skillpulse-ingress -n skillpulse
```
Look at Events. Common causes:
- ALB controller not running: `kubectl get pods -n kube-system | grep alb`
- IAM permission denied: check ALB controller pod logs
- Stale webhook cert: CD workflow handles this automatically

### `x509: certificate signed by unknown authority` during CD

ALB controller webhook has stale certs. The CD workflow already handles this:
```bash
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
```

### `InvalidImageName` on pods

Deployment was applied without running the `sed` substitution. The image name still contains the literal string `DOCKERHUB_USERNAME`. Always deploy via CD workflow, not manual `kubectl apply`.

### Terraform fails on fresh cluster — circular dependency

This was already fixed. The EBS CSI addon no longer references an IRSA role, so `terraform apply` works in a single pass.

---

## Summary

| Step | Tool | Who/What triggers it |
|------|------|---------------------|
| Write code | Editor | Developer |
| Create cluster | Terraform via GitHub Actions | Developer (one-time) |
| Build images | GitHub Actions CI | Developer (manual trigger) |
| Push images | Docker Hub | CI workflow |
| Deploy to EKS | GitHub Actions CD | Auto after CI |
| Route traffic | AWS ALB | Created by ALB Ingress Controller |
| Store data | AWS EBS | Created by EBS CSI Driver |

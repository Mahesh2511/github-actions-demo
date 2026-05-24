# SkillPulse — EKS CI/CD Demo

A three-tier skill-tracking web application demonstrating end-to-end DevOps automation: GitHub Actions CI/CD, Docker Compose for local development, Terraform for AWS EKS provisioning, and Kubernetes for production deployment.

## Architecture

```
Internet
   ↓
AWS ALB (Ingress)
   ↓
Kubernetes Ingress Controller
   ├── /        → Frontend (Nginx) — port 80
   ├── /api/*   → Backend (Go API) — port 8080
   └── /health  → Backend health check
                      ↓
                 MySQL (StatefulSet + PVC) — port 3306
```

**Stack:**
- **Backend:** Go 1.26 + Gin framework
- **Frontend:** Vanilla HTML/CSS/JS served by Nginx
- **Database:** MySQL 8.4 (StatefulSet with 5Gi EBS PVC)
- **Infra:** AWS EKS (ap-south-1), Terraform, Kubernetes
- **CI/CD:** GitHub Actions → Docker Hub → EKS

---

## CI/CD Pipelines

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| CI | `ci.yml` | Manual dispatch | Builds backend + frontend Docker images, pushes to Docker Hub tagged with commit SHA |
| CD (EKS) | `cd-eks.yml` | Auto on CI success / manual | Deploys full stack to EKS in correct order |
| EKS Provision | `EKS_deployment.yaml` | Manual (apply/destroy) | Runs Terraform to create/destroy EKS cluster |
| CD (EC2) | `cd.yml` | Auto on CI success | Legacy EC2 Docker Compose deployment |

### Deployment Order (CD)
1. Namespace
2. ConfigMap + Secrets
3. MySQL StatefulSet → wait ready
4. Backend Deployment + Service
5. Frontend Deployment + Service
6. ALB Ingress

---

## Kubernetes Structure

```
k8s/
├── namespace.yml
├── configmap.yml          # DB config + init.sql
├── secrets.yml            # DB credentials (base64)
├── ingress.yml            # ALB internet-facing ingress
├── backend/
│   ├── deployment.yml     # 2 replicas, /health probes
│   └── service.yml        # ClusterIP :8080
├── frontend/
│   ├── deployment.yml     # 2 replicas
│   └── service.yml        # ClusterIP :80
└── mysql/
    ├── statefulset.yml    # MySQL 8.4, init.sql mounted
    ├── service.yml        # Headless ClusterIP :3306
    └── pvc.yml            # 5Gi gp2 EBS volume
```

---

## Infrastructure (Terraform)

### EKS Cluster — `terraform/k8/`
- Cluster: `demo-eks-webapp-v25` (Kubernetes 1.33)
- Region: `ap-south-1` (Mumbai)
- Node group: 2× t3.small/t3.medium (ON_DEMAND, AL2023)
- VPC: 10.0.0.0/16 with public + private subnets across 2 AZs
- Remote state: S3 bucket `my-terraform-state-eks-demo` + DynamoDB lock
- Addons: `aws-ebs-csi-driver` (required for PVC provisioning on EKS 1.23+, policy attached via node group role)
- IRSA roles: AWS Load Balancer Controller only (EBS CSI uses node group IAM policy instead to avoid circular Terraform dependency)

### EC2 — `terraform/`
- Standalone VPC + t3.micro Amazon Linux instance for Docker Compose deployment

---

## Local Development

```bash
cp .env.example .env          # configure credentials
docker-compose up -d          # start db + backend + nginx
docker-compose logs -f
docker-compose down -v
```

### Backend only

```bash
cd backend
go mod tidy
go build -o skillpulse .
./skillpulse                  # runs on :8080
```

---

## Required GitHub Secrets

| Secret | Used by |
|---|---|
| `DOCKERHUB_USERNAME` | CI, CD |
| `DOCKERHUB_TOKEN` | CI |
| `AWS_ACCESS_KEY_ID` | CD (EKS), EKS provision |
| `AWS_SECRET_ACCESS_KEY` | CD (EKS), EKS provision |
| `HOST` | CD (EC2) |
| `EC2_USER` | CD (EC2) |
| `EC2_SSH_KEY` | CD (EC2) |

---

## Spinning Up the EKS Cluster

1. Ensure S3 bucket `my-terraform-state-eks-demo` and DynamoDB table `terraform-lock` exist in `ap-south-1`
2. Go to **Actions → EKS k8 Deploy → Run workflow** → action: `apply`
3. Wait ~12 minutes for cluster + node group + IAM roles

Terraform provisions everything in one pass: VPC, EKS cluster, node group (with EBS CSI policy), `aws-ebs-csi-driver` addon, and ALB controller IAM role. No manual post-steps needed.

> **Known issue on re-spin:** If you previously destroyed the cluster, delete the CloudWatch log group `/aws/eks/demo-eks-webapp-v25/cluster` manually before re-applying — otherwise Terraform fails with `ResourceAlreadyExistsException`. Delete via AWS Console (CloudWatch → Log groups) or:
> ```powershell
> aws logs delete-log-group --log-group-name /aws/eks/demo-eks-webapp-v25/cluster --region ap-south-1
> ```

---

## Connecting to the Cluster Locally

### 1. Install kubectl (if not installed)

**Windows:**
```powershell
winget install -e --id Kubernetes.kubectl
```
Or with Chocolatey: `choco install kubernetes-cli`

**Mac:**
```bash
brew install kubectl
```

**Linux:**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

Verify: `kubectl version --client`

### 2. Configure AWS CLI (if not done)

```powershell
aws configure
# Enter: AWS Access Key ID, Secret Access Key, region: ap-south-1, output: json
```

### 3. Connect to EKS

```powershell
aws eks update-kubeconfig --name demo-eks-webapp-v25 --region ap-south-1
kubectl get nodes
```

Should show 2 nodes in `Ready` state.

### 4. Get the app URL

```powershell
kubectl get ingress skillpulse-ingress -n skillpulse
```

The `ADDRESS` column is the ALB hostname — open it in your browser.

Alternatively: **AWS Console → EC2 → Load Balancers** (ap-south-1) → copy the DNS name of the `k8s-skillpul-*` ALB.

---

## Running CI/CD

**Full deployment:**
1. **Actions → TWS CI Workflow → Run workflow** — builds + pushes both images
2. CD triggers automatically — deploys to EKS
3. Get the URL:
   ```powershell
   kubectl get ingress skillpulse-ingress -n skillpulse
   ```

**Manual CD dispatch:** Actions → TWS CD EKS Workflow → Run workflow

---

## Useful kubectl Commands

```powershell
# Check all resources
kubectl get all -n skillpulse

# Watch pods
kubectl get pods -n skillpulse -w

# ALB URL
kubectl get ingress skillpulse-ingress -n skillpulse

# MySQL logs
kubectl logs statefulset/mysql -n skillpulse

# Backend logs
kubectl logs deployment/backend -n skillpulse

# Rollback
kubectl rollout undo deployment/backend -n skillpulse
kubectl rollout undo deployment/frontend -n skillpulse
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MySQL root password |
| `DB_NAME` | Database name (`skillpulse`) |
| `DB_USER` | App DB user (`skillpulse`) |
| `DB_PASSWORD` | App DB password |
| `DOCKERHUB_USERNAME` | Docker Hub username for image pull |

---

## Authors

- **Mahesh Pawar** — [@Mahesh2511](https://github.com/Mahesh2511)

**Fork of:** [LondheShubham153/github-actions-demo](https://github.com/LondheShubham153/github-actions-demo)

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SkillPulse is a three-tier skill-tracking web application used to demonstrate end-to-end DevOps automation: GitHub Actions CI/CD, Docker Compose for local dev, Terraform for AWS infrastructure (EC2 and EKS), and Kubernetes manifests.

- **Backend:** Go 1.26 + Gin framework, REST API on port 8080 (`github.com/trainwithshubham/skillpulse`)
- **Frontend:** Vanilla HTML/CSS/JS served by Nginx on port 80
- **Database:** MySQL 8.4, schema in `mysql/init.sql`

## Common Commands

### Local Development

```bash
cp .env.example .env          # set credentials first
docker-compose up -d          # start all three services (db, backend, nginx)
docker-compose logs -f        # tail logs
docker-compose down -v        # stop and remove volumes
```

### Backend (Go)

```bash
cd backend
go mod tidy
go build -o skillpulse .
./skillpulse                  # runs on :8080
```

Run a single test:
```bash
cd backend
go test ./handlers/... -run TestFunctionName -v
```

### Terraform – EC2

```bash
cd terraform
terraform init
terraform plan
terraform apply
terraform destroy
```

### Terraform – EKS

```bash
cd terraform/k8
terraform init                # uses S3 backend (bucket: my-terraform-state-eks-demo)
terraform plan
terraform apply
terraform destroy
```

> EKS Terraform uses a remote S3 state backend + DynamoDB lock table — ensure AWS credentials and the S3 bucket exist before running.

### Kubernetes

```bash
kubectl apply -f k8s/namespace.yml
kubectl apply -f k8s/mysql-configmap.yml
```

## Architecture

```
Internet → Nginx (:80) → static frontend  (./frontend/)
                       → /api/*  →  Go backend (:8080) → MySQL (:3306)
                       → /health → Go backend health check
```

Docker Compose wires the three containers using service names (`db`, `backend`, `nginx`). Nginx config is at `nginx/nginx.conf`.

### Backend Code Layout

| Path | Purpose |
|------|---------|
| `backend/main.go` | Route registration, server startup |
| `backend/database/db.go` | MySQL connection pool (reads env vars) |
| `backend/handlers/` | Gin route handlers: skills, logs, dashboard |
| `backend/models/skill.go` | Shared data structs |

### CI/CD Workflows (`.github/workflows/`)

| File | Trigger | What it does |
|------|---------|--------------|
| `ci.yml` | Manual dispatch | Builds and pushes `{DOCKERHUB_USERNAME}/skillpulse-backend:shyam` to Docker Hub |
| `cd.yml` | CI workflow completes | SSHes into EC2, pulls image, restarts docker-compose stack |
| `EKS_deployment.yaml` | Manual dispatch (apply/destroy) | Runs Terraform in `./terraform/k8` to create/destroy EKS cluster |

### Required GitHub Secrets

- **CI/CD:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `HOST`, `EC2_USER`, `EC2_SSH_KEY`
- **EKS:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

## Infrastructure

- **AWS Region:** ap-south-1 (Mumbai)
- **EC2 Terraform (`terraform/`):** Creates VPC, public subnet, security group (SSH on 22), and a `t3.micro` Amazon Linux instance.
- **EKS Terraform (`terraform/k8/`):** Creates VPC with public/private subnets, EKS cluster `demo-eks-webapp-v25` (k8s 1.33), managed node group (t3.small/t3.medium, 2 nodes).

## Environment Variables

Copy `.env.example` to `.env` before running locally. Key variables:

- `MYSQL_ROOT_PASSWORD`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — MySQL credentials
- `DOCKERHUB_USERNAME` — used by docker-compose to pull the backend image

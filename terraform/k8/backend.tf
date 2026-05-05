terraform {
  backend "s3" {
    bucket         = "my-terraform-state-eks-demo"
    key            = "env/dev/eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
}

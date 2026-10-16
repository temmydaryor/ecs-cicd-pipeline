variable "aws_region" {
  description = "Region to deploy into. Fargate is supported in ca-west-1."
  type        = string
  default     = "ca-west-1"
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "ecs-cicd"
}

variable "github_org" {
  description = "GitHub user or org that owns the repo (case-sensitive, must match exactly)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (case-sensitive, must match exactly)."
  type        = string
}

variable "github_sub_prefix" {
  description = <<-EOT
    Leave empty for classic repos (trust uses repo:ORG/REPO).
    Newer repos use GitHub's immutable subject, which contains numeric IDs. Get yours with:
      gh api repos/ORG/REPO/actions/oidc/customization/sub
    and paste the sub_claim_prefix value here, e.g. repo:ORG@123456/REPO@7891011
  EOT
  type        = string
  default     = ""
}

variable "github_environment" {
  description = "GitHub Environment that gates deploys (Settings > Environments)."
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = "Set to false if your account already has the token.actions.githubusercontent.com OIDC provider (only one is allowed per account)."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarm notifications (you must click the confirmation link)."
  type        = string
}

variable "image_tag" {
  description = "Image tag Terraform uses for the FIRST task definition. Push this tag to ECR manually before the full apply. The pipeline owns the image after that."
  type        = string
  default     = "manual-v1"
}

variable "desired_count" {
  description = "Number of Fargate tasks. Use 2+ for zero-downtime rolling deploys."
  type        = number
  default     = 2
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "task_cpu" {
  type    = number
  default = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

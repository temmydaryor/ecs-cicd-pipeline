<#
.SYNOPSIS
  Copies Terraform outputs into GitHub Actions repository variables (needs: gh auth login).
  These are NOT secrets - role ARNs and names are safe as variables; no AWS keys exist anywhere.

.EXAMPLE
  .\scripts\set-github-vars.ps1 -GitHubRepo "YOUR_USER/ecs-cicd-pipeline"
#>
param(
  [Parameter(Mandatory)][string]$GitHubRepo,
  [string]$Region = "ca-west-1"
)

$ErrorActionPreference = "Stop"
$o = terraform -chdir=infra output -json | ConvertFrom-Json

$vars = @{
  AWS_REGION          = $Region
  ECR_REPOSITORY      = $o.ecr_repository_name.value
  ECS_CLUSTER         = $o.ecs_cluster_name.value
  ECS_SERVICE         = $o.ecs_service_name.value
  AWS_BUILD_ROLE_ARN  = $o.github_build_role_arn.value
  AWS_DEPLOY_ROLE_ARN = $o.github_deploy_role_arn.value
  APP_URL             = $o.alb_url.value
  FAIL_ON_CRITICAL    = "false"
}

foreach ($k in $vars.Keys) {
  gh variable set $k --body $vars[$k] --repo $GitHubRepo
  if ($LASTEXITCODE) { throw "failed to set $k" }
  Write-Host "set $k"
}

<#
.SYNOPSIS
  Phase 2: push the very first image to ECR by hand to prove the target works
  BEFORE the full Terraform apply creates the ECS service.

.EXAMPLE
  .\scripts\push-first-image.ps1
#>
param(
  [string]$Tag     = "manual-v1",
  [string]$Region  = "ca-west-1",
  [string]$Project = "ecs-cicd"
)

$ErrorActionPreference = "Stop"
$Repo     = "$Project-app"
$account  = aws sts get-caller-identity --query Account --output text
$registry = "$account.dkr.ecr.$Region.amazonaws.com"
$image    = "$registry/${Repo}:$Tag"

docker build --platform linux/amd64 --build-arg GIT_SHA=$Tag -t $image .
if ($LASTEXITCODE) { throw "docker build failed" }

$pw = (aws ecr get-login-password --region $Region | Out-String).Trim()
if ($LASTEXITCODE -or -not $pw) { throw "aws ecr get-login-password returned nothing - fix AWS credentials/region first (aws sts get-caller-identity)" }
docker login --username AWS --password $pw $registry
if ($LASTEXITCODE) { throw "docker login to ECR failed (credentials were fine, so check Docker Desktop is running and try: docker logout $registry)" }

docker push $image
if ($LASTEXITCODE) { throw "docker push failed" }

Write-Host "`nPushed $image"
docker image ls $image --format "Local image size: {{.Size}}"
aws ecr describe-images --repository-name $Repo --region $Region `
  --query "imageDetails[].{tag:imageTags[0],sizeMB:imageSizeInBytes}" --output table
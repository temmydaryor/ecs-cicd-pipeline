<#
.SYNOPSIS
  Emergency rollback from your laptop (same effect as the "rollback" GitHub workflow).
  Without -Revision it restores the most recent ACTIVE revision that is not the current one.

.EXAMPLE
  .\scripts\rollback.ps1
  .\scripts\rollback.ps1 -Revision 7
#>
param(
  [int]$Revision = 0,
  [string]$Region  = "ca-west-1",
  [string]$Project = "ecs-cicd"
)

$ErrorActionPreference = "Stop"
$Cluster = "$Project-cluster"
$Service = "$Project-service"

$current = aws ecs describe-services --cluster $Cluster --services $Service --region $Region `
           --query "services[0].taskDefinition" --output text
$family  = ($current -split "/")[-1] -replace ":\d+$", ""

if ($Revision -gt 0) {
  $target = "${family}:$Revision"
} else {
  $all = aws ecs list-task-definitions --family-prefix $family --status ACTIVE --sort DESC --region $Region `
         --query "taskDefinitionArns" --output json | ConvertFrom-Json
  $target = $all | Where-Object { $_ -ne $current } | Select-Object -First 1
}

if (-not $target) { throw "No earlier ACTIVE revision found to roll back to." }
Write-Host "Rolling back`n  from: $current`n  to:   $target"

aws ecs update-service --cluster $Cluster --service $Service --task-definition $target `
  --force-new-deployment --region $Region | Out-Null
aws ecs wait services-stable --cluster $Cluster --services $Service --region $Region
Write-Host "Done - service is stable on $target"

<#
.SYNOPSIS
  The "BEFORE" measurement: deploys by hand (build -> push -> new task definition -> update service)
  and prints how long each phase took. Compare the total with the pipeline's deploy time.

.EXAMPLE
  .\scripts\manual-deploy.ps1 -Tag manual-v2
#>
param(
  [Parameter(Mandatory)][string]$Tag,
  [string]$Region  = "ca-west-1",
  [string]$Project = "ecs-cicd"
)

$ErrorActionPreference = "Stop"
$Repo    = "$Project-app"
$Cluster = "$Project-cluster"
$Service = "$Project-service"

$account = (aws sts get-caller-identity --query Account --output text)
$registry = "$account.dkr.ecr.$Region.amazonaws.com"
$image    = "$registry/${Repo}:$Tag"

$timings = [ordered]@{}
$total = [System.Diagnostics.Stopwatch]::StartNew()
function Time-Phase($name, [scriptblock]$block) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $block
  $sw.Stop()
  $script:timings[$name] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}

Time-Phase "docker build" {
  # --platform matters on ARM laptops: Fargate task def in this project is X86_64.
  docker build --platform linux/amd64 --build-arg GIT_SHA=$Tag -t $image .
  if ($LASTEXITCODE) { throw "docker build failed" }
}

Time-Phase "ecr login + push" {
  aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry
  if ($LASTEXITCODE) { throw "ecr login failed" }
  docker push $image
  if ($LASTEXITCODE) { throw "docker push failed" }
}

Time-Phase "register task definition" {
  $current = aws ecs describe-services --cluster $Cluster --services $Service --region $Region `
             --query "services[0].taskDefinition" --output text
  $td = aws ecs describe-task-definition --task-definition $current --region $Region `
        --query taskDefinition | ConvertFrom-Json
  $td.containerDefinitions[0].image = $image
  foreach ($p in 'taskDefinitionArn','revision','status','requiresAttributes','compatibilities','registeredAt','registeredBy') {
    $td.PSObject.Properties.Remove($p)
  }
  # -Depth 20: the default depth (2) silently truncates nested container settings.
  # No BOM: Windows PowerShell 5.1 'Set-Content -Encoding UTF8' adds one and the AWS CLI rejects it.
  $json = $td | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText("$PWD\td-manual.json", $json, (New-Object System.Text.UTF8Encoding $false))
  aws ecs register-task-definition --cli-input-json file://td-manual.json --region $Region | Out-Null
  if ($LASTEXITCODE) { throw "register-task-definition failed" }
  Remove-Item td-manual.json
}

Time-Phase "update service + wait for stable" {
  $family = "$Project-app"
  aws ecs update-service --cluster $Cluster --service $Service --task-definition $family --region $Region | Out-Null
  aws ecs wait services-stable --cluster $Cluster --services $Service --region $Region
  if ($LASTEXITCODE) { throw "service did not stabilise" }
}

$total.Stop()
Write-Host "`n=== MANUAL DEPLOY TIMINGS ($Tag) ==="
$timings.GetEnumerator() | ForEach-Object { "{0,-34} {1,8} s" -f $_.Key, $_.Value }
"{0,-34} {1,8} s  (~{2} min)" -f "TOTAL (machine time only)", [math]::Round($total.Elapsed.TotalSeconds,1), [math]::Round($total.Elapsed.TotalMinutes,1)
Write-Host "`nAlso add the time you spent typing commands / clicking between steps - that is part of the real manual cost."

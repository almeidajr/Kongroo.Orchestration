#requires -Version 7
<#
.SYNOPSIS
  End a cloud day: disarm CI, delete the kongroo namespace and the cluster stack, and prove nothing is left billing.
.DESCRIPTION
  Prints "safe to End Lab" only when no PVC volume, cluster-tagged load balancer or cluster-tagged instance is left; otherwise it
  fails naming them. The registry stack and the kongroo-notifications SAM stack stay. Safe to rerun, also after a failed up.ps1.
#>
$ErrorActionPreference = "Stop"
$region = "us-east-1"
$cluster = "kongroo"
$clusterStack = "kongroo-cluster"
$kubeContext = "kongroo-eks"
$clusterTag = "kubernetes.io/cluster/$cluster"

aws sts get-caller-identity | Out-Null
if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: refresh credentials" }

function Get-AwsList([string[]]$Arguments) {
    $json = aws @Arguments --region $region --output json
    if ($LASTEXITCODE -ne 0) { throw "aws $($Arguments[0..1] -join ' ') failed" }
    @(($json -join "`n") | ConvertFrom-Json)
}

function Get-PvcVolume {
    Get-AwsList "ec2", "describe-volumes", "--filters", "Name=tag-key,Values=kubernetes.io/created-for/pvc/name", "--query", "Volumes[].VolumeId"
}

function Get-ClusterLoadBalancer {
    $names = Get-AwsList "elb", "describe-load-balancers", "--query", "LoadBalancerDescriptions[].LoadBalancerName"
    if (-not $names) { return }
    # shortcut: describe-tags takes at most 20 names; a Learner Lab account holds far fewer. Chunk the names if that changes.
    Get-AwsList (@("elb", "describe-tags", "--query", "TagDescriptions", "--load-balancer-names") + $names) |
        Where-Object { $_.Tags.Key -contains $clusterTag } | ForEach-Object LoadBalancerName
}

function Get-ClusterInstance {
    Get-AwsList "ec2", "describe-instances", "--filters", "Name=tag-key,Values=$clusterTag",
    "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped", "--query", "Reservations[].Instances[].InstanceId"
}

& "$PSScriptRoot/arm.ps1" -Disarm

# Kong's ELB and the CSI-created EBS volumes are not in the stack: they go with the namespace, while the nodes still run.
$clusterStatus = aws eks describe-cluster --region $region --name $cluster --query cluster.status --output text 2>$null
if ($clusterStatus -eq "ACTIVE") {
    $existingContext = kubectl config get-contexts $kubeContext -o name 2>$null
    if (-not $existingContext) {
        $previousContext = kubectl config current-context 2>$null
        try {
            aws eks update-kubeconfig --region $region --name $cluster --alias $kubeContext
            if ($LASTEXITCODE -ne 0) { throw "aws eks update-kubeconfig failed" }
        }
        finally {
            if ($previousContext) { kubectl config use-context $previousContext | Out-Null }
        }
    }
    Write-Output "Deleting namespace kongroo (Kong's load balancer and every PVC)"
    kubectl --context $kubeContext delete namespace kongroo --ignore-not-found --wait --timeout=15m
    if ($LASTEXITCODE -ne 0) { throw "kubectl delete namespace kongroo failed" }
}
else {
    Write-Output "Cluster $cluster is not ACTIVE ($($clusterStatus ?? 'absent')): no namespace to delete"
}

Write-Output "Waiting for the PVC volumes and the cluster-tagged load balancer to go"
$deadline = (Get-Date).AddMinutes(10)
while (($left = @(Get-PvcVolume) + @(Get-ClusterLoadBalancer)) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 15 }
if ($left) { throw "Still present after 10 minutes: $($left -join ', '). Delete them in the EC2 console, then rerun down.ps1" }

Write-Output "Deleting stack $clusterStack"
aws cloudformation delete-stack --region $region --stack-name $clusterStack
if ($LASTEXITCODE -ne 0) { throw "aws cloudformation delete-stack failed" }
aws cloudformation wait stack-delete-complete --region $region --stack-name $clusterStack
if ($LASTEXITCODE -ne 0) { throw "Stack $clusterStack did not reach DELETE_COMPLETE: read its events, remove what blocks it, rerun down.ps1" }

$leftovers = [ordered]@{
    "PVC volumes"                   = Get-PvcVolume
    "cluster-tagged load balancers" = Get-ClusterLoadBalancer
    "cluster-tagged instances"      = Get-ClusterInstance
}
$billing = @($leftovers.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "$($_.Key): $($_.Value -join ', ')" })
if ($billing) { throw "NOT safe to End Lab, still billing: $($billing -join '; ')" }

$entry = (kubectl config view -o json | ConvertFrom-Json).contexts | Where-Object name -EQ $kubeContext
if ($entry) {
    kubectl config delete-context $kubeContext | Out-Null
    kubectl config delete-cluster $entry.context.cluster | Out-Null
    kubectl config delete-user $entry.context.user | Out-Null
}

Write-Output "Cluster stack deleted; no PVC volume, load balancer or node left. Registry and kongroo-notifications stacks kept. safe to End Lab"

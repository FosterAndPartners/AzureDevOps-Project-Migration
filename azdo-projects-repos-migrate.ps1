# Edit these
$sourceOrg = Read-Host
$targetOrg = Read-Host
$sourcePAT = Read-Host -AsSecureString "Source PAT" | ConvertFrom-SecureString
$targetPAT = Read-Host -AsSecureString "Target PAT" | ConvertFrom-SecureString

# Helper to convert secure string to plain (prompting once) - replace with plain text variables if you prefer
function Get-Plain([string]$enc) {
  $b = ConvertTo-SecureString $enc
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
  try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$sourcePAT = Get-Plain $sourcePAT
$targetPAT = Get-Plain $targetPAT

$apiVersion = '?api-version=7.1'
$tempDir = Join-Path $PWD "azdo_migrate_temp"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

# Basic REST wrapper
function Invoke-AzDo {
    param($Method, $Org, $UriPath, $Body, $Pat)
    $base = "https://dev.azure.com/$Org"
    $url = "$base/$UriPath" + "$apiVersion"
    Write-Host "AzDo Request URL: $url"
    $pair = ":$Pat"
    $b = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $hdr = @{ Authorization = "Basic $b"; "Content-Type" = "application/json" }
    if ($Body) { $json = $Body | ConvertTo-Json -Depth 10; Invoke-RestMethod -Method $Method -Uri $url -Headers $hdr -Body $json }
    else { Invoke-RestMethod -Method $Method -Uri $url -Headers $hdr }
}

# 1) Get projects from source
$projectsResp = Invoke-AzDo -Method Get -Org $sourceOrg -UriPath "_apis/projects" -Body $null -Pat $sourcePAT
$projects = $projectsResp.value

# Option: create projects in target if they don't exist
Write-Host "Create missing projects in target? (y/N)"
$createProjects = Read-Host
if ($createProjects -match '^[Yy]') {
    foreach ($p in $projects) {
        $name = $p.name
        # check exists
        try {
            $exists = Invoke-AzDo -Method Get -Org $targetOrg -UriPath "_apis/projects/$name" -Body $null -Pat $targetPAT
            Write-Host "Project exists in target: $name"
        } catch {
            Write-Host "Creating project: $name"
            $body = @{
                name = $name
                description = "Created by migration from $sourceOrg"
                capabilities = @{
                    versioncontrol = @{ sourceControlType = "Git" }
                    processTemplate = @{ templateTypeId = "adcc42ab-9882-485e-a3ed-7678f01f66bc" }
                }
            }
            Invoke-AzDo -Method Post -Org $targetOrg -UriPath "_apis/projects" -Body $body -Pat $targetPAT
            Write-Host "Create request submitted for $name (project creation can take some time)."
        }
    }
}

# 2) For each project, list repos and migrate
foreach ($p in $projects) {
    $projName = $p.name
    Write-Host "Processing project: $projName"
    $reposResp = Invoke-AzDo -Method Get -Org $sourceOrg -UriPath "$projName/_apis/git/repositories" -Body $null -Pat $sourcePAT
    $repos = $reposResp.value
    
    foreach ($r in $repos) {
        $repoName = $r.name
        Write-Host "  Repo: $repoName"
        
        # Create repo in target (if not exists)
        $targetRepoExists = $false
        try {
            $check = Invoke-AzDo -Method Get -Org $targetOrg -UriPath "$projName/_apis/git/repositories/$repoName" -Body $null -Pat $targetPAT
            $targetRepoExists = $true
            Write-Host "    Target repo exists."
        } catch {
            Write-Host "    Creating target repo..."
            $body = @{ name = $repoName }
            $created = Invoke-AzDo -Method Post -Org $targetOrg -UriPath "$projName/_apis/git/repositories" -Body $body -Pat $targetPAT
            $targetRepoExists = $true
            Start-Sleep -Seconds 1
        }
        
        # Mirror clone & push
        $work = Join-Path $tempDir "$projName`_$repoName.git"
        if (Test-Path $work) { Remove-Item -Recurse -Force $work }
        $srcUrl = "https://user:$sourcePAT@dev.azure.com/$sourceOrg/$projName/_git/$repoName"
        $dstUrl = "https://user:$targetPAT@dev.azure.com/$targetOrg/$projName/_git/$repoName"
        
        Write-Host "    Cloning --mirror..."
        git clone --mirror $srcUrl $work
        if ($LASTEXITCODE -ne 0) { Write-Host "Clone failed for $repoName"; continue }
        
        Push-Location $work
        Write-Host "    Pushing --mirror to target..."
        git remote remove target 2>$null
        git remote add target $dstUrl
        git push --mirror target
        if ($LASTEXITCODE -ne 0) { Write-Host "Push failed for $repoName" } else { Write-Host "    Migrated $repoName" }
        Pop-Location
        
        # Optional: remove local mirror to save space
        # Remove-Item -Recurse -Force $work
    }
}

Write-Host "Done. Remove $tempDir if you don't need logs or temp clones."
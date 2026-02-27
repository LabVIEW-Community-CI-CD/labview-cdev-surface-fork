#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SyncGuardRepository = 'LabVIEW-Community-CI-CD/labview-cdev-cli',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$ForkRepository = 'svelderrainruiz/labview-cdev-cli',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$SyncGuardBranch = 'main',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SyncGuardWorkflow = 'fork-upstream-sync-guard',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [string[]]$RequiredAssets = @(
        'cdev-cli-win-x64.zip',
        'cdev-cli-linux-x64.tar.gz'
    ),

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$RuntimePublishRepository = 'LabVIEW-Community-CI-CD/labview-cdev-cli',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$RuntimePublishBranch = 'main',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RuntimePublishWorkflow = 'publish-cli-runtime-image',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RuntimeAttestationArtifactName = 'cli-dependency-attestation',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedRuntimeRepository = 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime',

    [Parameter()]
    [string]$ExpectedRuntimeDigest = '',

    [Parameter()]
    [string]$ExpectedRuntimeSourceCommit = '',

    [Parameter()]
    [ValidateSet('hard_block', 'warn_only')]
    [string]$EnforcementMode = 'hard_block',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

function Get-RunTimestampUtc {
    param([Parameter(Mandatory = $true)][object]$Run)

    $value = [DateTimeOffset]::MinValue
    $created = [string]$Run.createdAt
    if ([string]::IsNullOrWhiteSpace($created)) {
        return $value
    }

    if ([DateTimeOffset]::TryParse($created, [ref]$value)) {
        return $value.ToUniversalTime()
    }

    return [DateTimeOffset]::MinValue
}

function Convert-RunRecord {
    param([Parameter()][object]$Run)

    if ($null -eq $Run) {
        return $null
    }

    $timestamp = Get-RunTimestampUtc -Run $Run
    return [ordered]@{
        run_id = [string]$Run.databaseId
        status = [string]$Run.status
        conclusion = [string]$Run.conclusion
        head_sha = [string]$Run.headSha
        event = [string]$Run.event
        created_at_utc = if ($timestamp -eq [DateTimeOffset]::MinValue) { '' } else { $timestamp.ToString('o') }
        url = [string]$Run.url
    }
}

function Get-ReleaseAssetDigestMap {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $release = Invoke-GhJson -Arguments @('release', 'view', $Tag, '-R', $Repository, '--json', 'assets')
    $map = @{}
    foreach ($asset in @($release.assets)) {
        $name = [string]$asset.name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $map[$name] = [string]$asset.digest
        }
    }
    return $map
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    status = 'fail'
    enforcement_mode = $EnforcementMode
    reason_codes = @()
    message = ''
    sync_guard_evidence = [ordered]@{
        repository = $SyncGuardRepository
        workflow = $SyncGuardWorkflow
        branch = $SyncGuardBranch
        max_age_hours = $SyncGuardMaxAgeHours
        latest_run = $null
        latest_completed_run = $null
        latest_success_run = $null
        latest_success_age_hours = $null
        branch_parity = $null
        release_parity = $null
        asset_parity = @()
    }
    runtime_evidence = [ordered]@{
        publish_repository = $RuntimePublishRepository
        publish_workflow = $RuntimePublishWorkflow
        publish_branch = $RuntimePublishBranch
        latest_publish_run = $null
        attestation_artifact_name = $RuntimeAttestationArtifactName
        expected_runtime_repository = $ExpectedRuntimeRepository
        expected_runtime_digest = $ExpectedRuntimeDigest
        expected_runtime_source_commit = $ExpectedRuntimeSourceCommit
        attestation = $null
    }
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cli-dependency-gate-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

try {
    $syncRuns = @(
        Get-GhWorkflowRunsPortable `
            -Repository $SyncGuardRepository `
            -Workflow $SyncGuardWorkflow `
            -Branch $SyncGuardBranch `
            -Limit 20
    )
    if (@($syncRuns).Count -gt 0) {
        $report.sync_guard_evidence.latest_run = Convert-RunRecord -Run $syncRuns[0]
    }

    $latestCompleted = @($syncRuns | Where-Object { [string]$_.status -eq 'completed' } | Select-Object -First 1)
    if (@($latestCompleted).Count -eq 1) {
        $report.sync_guard_evidence.latest_completed_run = Convert-RunRecord -Run $latestCompleted[0]
        if ([string]$latestCompleted[0].conclusion -ne 'success') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_failed'
        }
    }

    $latestSuccess = @($syncRuns | Where-Object { [string]$_.status -eq 'completed' -and [string]$_.conclusion -eq 'success' } | Select-Object -First 1)
    if (@($latestSuccess).Count -eq 1) {
        $successRun = $latestSuccess[0]
        $report.sync_guard_evidence.latest_success_run = Convert-RunRecord -Run $successRun
        $successTimestamp = Get-RunTimestampUtc -Run $successRun
        $ageHours = [Math]::Round((((Get-Date).ToUniversalTime() - $successTimestamp.UtcDateTime).TotalHours), 2)
        $report.sync_guard_evidence.latest_success_age_hours = $ageHours
        if ($ageHours -gt $SyncGuardMaxAgeHours) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_stale'
        }
    } else {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_missing'
    }

    $upstreamHead = (Invoke-GhText -Arguments @('api', "repos/$SyncGuardRepository/commits/$SyncGuardBranch", '--jq', '.sha')).Trim()
    $forkHead = (Invoke-GhText -Arguments @('api', "repos/$ForkRepository/commits/$SyncGuardBranch", '--jq', '.sha')).Trim()
    $branchMatches = [string]::Equals($upstreamHead, $forkHead, [System.StringComparison]::Ordinal)
    $report.sync_guard_evidence.branch_parity = [ordered]@{
        upstream_head = $upstreamHead
        fork_head = $forkHead
        matches = $branchMatches
    }
    if (-not $branchMatches) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'parity_main_head_mismatch'
    }

    $upstreamTag = (Invoke-GhText -Arguments @('api', "repos/$SyncGuardRepository/releases/latest", '--jq', '.tag_name')).Trim()
    $forkTag = (Invoke-GhText -Arguments @('api', "repos/$ForkRepository/releases/latest", '--jq', '.tag_name')).Trim()
    $releaseMatches = [string]::Equals($upstreamTag, $forkTag, [System.StringComparison]::Ordinal)
    $report.sync_guard_evidence.release_parity = [ordered]@{
        upstream_latest_tag = $upstreamTag
        fork_latest_tag = $forkTag
        matches = $releaseMatches
    }
    if (-not $releaseMatches) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'parity_latest_tag_mismatch'
    }

    $upstreamAssetMap = Get-ReleaseAssetDigestMap -Repository $SyncGuardRepository -Tag $upstreamTag
    $forkAssetMap = Get-ReleaseAssetDigestMap -Repository $ForkRepository -Tag $forkTag
    $assetParity = [System.Collections.Generic.List[object]]::new()
    foreach ($asset in @($RequiredAssets)) {
        $assetName = ([string]$asset).Trim()
        if ([string]::IsNullOrWhiteSpace($assetName)) {
            continue
        }

        $upstreamDigest = [string]$upstreamAssetMap[$assetName]
        $forkDigest = [string]$forkAssetMap[$assetName]
        $matches = (-not [string]::IsNullOrWhiteSpace($upstreamDigest)) -and
            (-not [string]::IsNullOrWhiteSpace($forkDigest)) -and
            [string]::Equals($upstreamDigest, $forkDigest, [System.StringComparison]::Ordinal)
        if (-not $matches) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode "parity_asset_digest_mismatch:$assetName"
        }

        $assetParity.Add([ordered]@{
                asset = $assetName
                upstream_digest = $upstreamDigest
                fork_digest = $forkDigest
                matches = $matches
            }) | Out-Null
    }
    $report.sync_guard_evidence.asset_parity = @($assetParity)

    $publishRuns = @(
        Get-GhWorkflowRunsPortable `
            -Repository $RuntimePublishRepository `
            -Workflow $RuntimePublishWorkflow `
            -Branch $RuntimePublishBranch `
            -Limit 10
    )
    $latestPublish = @($publishRuns | Where-Object { [string]$_.status -eq 'completed' } | Select-Object -First 1)
    if (@($latestPublish).Count -ne 1) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_publish_run_missing'
    } else {
        $publishRun = $latestPublish[0]
        $report.runtime_evidence.latest_publish_run = Convert-RunRecord -Run $publishRun

        $attestationRoot = Join-Path $scratchRoot 'attestation'
        New-Item -Path $attestationRoot -ItemType Directory -Force | Out-Null
        try {
            Invoke-Gh -Arguments @(
                'run',
                'download',
                [string]$publishRun.databaseId,
                '-R',
                $RuntimePublishRepository,
                '--name',
                $RuntimeAttestationArtifactName,
                '--dir',
                $attestationRoot
            )
        } catch {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_attestation_missing'
        }

        $attestationPath = Join-Path $attestationRoot 'cli-dependency-attestation.json'
        if (-not (Test-Path -LiteralPath $attestationPath -PathType Leaf)) {
            $candidate = Get-ChildItem -Path $attestationRoot -Recurse -Filter 'cli-dependency-attestation.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $candidate) {
                $attestationPath = $candidate.FullName
            }
        }

        if (-not (Test-Path -LiteralPath $attestationPath -PathType Leaf)) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_attestation_missing'
        } else {
            try {
                $attestation = Get-Content -LiteralPath $attestationPath -Raw | ConvertFrom-Json -Depth 30
                $attestationRepository = [string]$attestation.runtime_image.repository
                $attestationDigest = [string]$attestation.runtime_image.digest
                $attestationSourceCommit = [string]$attestation.source_commit
                $attestationStatus = [string]$attestation.status

                $report.runtime_evidence.attestation = [ordered]@{
                    path = [System.IO.Path]::GetFullPath($attestationPath)
                    schema_version = [string]$attestation.schema_version
                    generated_at_utc = [string]$attestation.generated_at_utc
                    status = $attestationStatus
                    source_commit = $attestationSourceCommit
                    runtime_image_repository = $attestationRepository
                    runtime_image_digest = $attestationDigest
                    parity_evidence = $attestation.parity_evidence
                    sync_guard_evidence = $attestation.sync_guard_evidence
                }

                if (-not [string]::IsNullOrWhiteSpace($ExpectedRuntimeRepository) -and
                    -not [string]::Equals($attestationRepository, $ExpectedRuntimeRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_repository_mismatch'
                }

                if (-not [string]::IsNullOrWhiteSpace($ExpectedRuntimeDigest) -and
                    -not [string]::Equals($attestationDigest, $ExpectedRuntimeDigest, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_digest_mismatch'
                }

                if (-not [string]::IsNullOrWhiteSpace($ExpectedRuntimeSourceCommit) -and
                    -not [string]::Equals($attestationSourceCommit, $ExpectedRuntimeSourceCommit, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_source_commit_mismatch'
                }

                if (-not [string]::Equals($attestationStatus, 'in_sync', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_attestation_reports_drift'
                }
            } catch {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_attestation_parse_failed'
            }
        }
    }

    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'CLI dependency gate passed.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "CLI dependency gate failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('cli_dependency_gate_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1

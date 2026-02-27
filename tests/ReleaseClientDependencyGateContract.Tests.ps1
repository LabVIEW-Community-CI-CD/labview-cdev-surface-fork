#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release client dependency gate contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-CliDependencyGate.ps1'

        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "CLI dependency gate script missing: $script:scriptPath"
        }

        $script:content = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines required evidence fields and deterministic reason-code model' {
        $script:content | Should -Match 'sync_guard_evidence'
        $script:content | Should -Match 'runtime_evidence'
        $script:content | Should -Match 'enforcement_mode'
        $script:content | Should -Match 'hard_block'
        $script:content | Should -Match 'warn_only'
        $script:content | Should -Match 'parity_main_head_mismatch'
        $script:content | Should -Match 'parity_latest_tag_mismatch'
        $script:content | Should -Match 'parity_asset_digest_mismatch'
        $script:content | Should -Match 'runtime_attestation_missing'
        $script:content | Should -Match 'runtime_digest_mismatch'
        $script:content | Should -Match 'runtime_source_commit_mismatch'
    }

    It 'uses portable workflow ops helpers and emits structured report output' {
        $script:content | Should -Match 'WorkflowOps\.Common\.ps1'
        $script:content | Should -Match 'Get-GhWorkflowRunsPortable'
        $script:content | Should -Match 'Write-WorkflowOpsReport'
        $script:content | Should -Match 'cli_dependency_gate_runtime_error'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:content, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}

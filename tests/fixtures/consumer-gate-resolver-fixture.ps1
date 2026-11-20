# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
param(
    [string]$PolicyPath,[string]$ToolName,[switch]$Install,[string]$InstallRoot,
    [string]$ExpectedGoRuntimeVersion,[string]$RunId,[string]$OutputPath,[int]$AcquisitionTimeoutSeconds
)
$ErrorActionPreference='Stop'
[void][IO.Directory]::CreateDirectory($InstallRoot)
$environment=[Environment]::GetEnvironmentVariables('Process')
$tokenNames=@($environment.Keys|ForEach-Object{[string]$_}|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'}|Sort-Object)
$sentinelHashPath=Join-Path (Split-Path -Parent $OutputPath) 'credential-sentinel.sha256'
$sentinelHash=if(Test-Path -LiteralPath $sentinelHashPath -PathType Leaf){[IO.File]::ReadAllText($sentinelHashPath).Trim()}else{''}
$sentinelValueNames=@($environment.Keys|ForEach-Object{[string]$_}|Where-Object{
        $value=[string]$environment[$_]
        -not[string]::IsNullOrEmpty($sentinelHash)-and-not[string]::IsNullOrEmpty($value)-and
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()-ceq$sentinelHash
    }|Sort-Object)
$dump=[ordered]@{tokenNames=$tokenNames;standardPresent=($tokenNames-ccontains'STANDARD_VALIDATION_GITHUB_API_TOKEN')
    githubPresent=($tokenNames-ccontains'GITHUB_TOKEN');ghPresent=($tokenNames-ccontains'GH_TOKEN');sentinelValueNames=$sentinelValueNames}
$dumpPath=Join-Path (Split-Path -Parent $OutputPath) "environment-$ToolName.json"
[IO.File]::WriteAllText($dumpPath,($dump|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$payload=Join-Path $InstallRoot "$ToolName-fixture.bin"
[IO.File]::WriteAllText($payload,"fixture $ToolName",[Text.UTF8Encoding]::new($false))
$sha=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
$receipt=[ordered]@{toolName=$ToolName;resolvedVersion=if($ToolName-eq'pester'){'6.2.0'}else{'1.0.0'}
    executablePath=$payload;executableSha256=$sha;modulePath=$payload
    nodePath=$payload;nodeSha256=$sha;entryPointPath=$payload;entryPointSha256=$sha}
[IO.File]::WriteAllText($OutputPath,($receipt|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PackageRoot,
    [string] $PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/upstream-adapter.json'),
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AdapterProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) { return $null }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ([string]$property.Name -ceq $Name) { return ,$property.Value }
    }
    return $null
}

function Assert-AdapterPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject -or $Object -is [string] -or $Object -is [array]) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "$Context contains unknown field '$name'." }
    }
    foreach ($name in $Expected) {
        $matches = @($actual | Where-Object { $_ -ceq $name })
        if ($matches.Count -gt 1) { throw "$Context contains duplicate field '$name'." }
    }
}

function Assert-AdapterString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $AllowEmpty
    )

    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$Value))) {
        throw "$Context must be a non-empty string."
    }
    if ([string]$Value -match '[\x00-\x1F\x7F]') { throw "$Context contains a control character." }
}

function Assert-AdapterExactString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-AdapterString -Value $Value -Context $Context
    if ([string]$Value -cne $Expected) { throw "$Context must be '$Expected'." }
}

function Assert-AdapterStringArray {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $AllowEmpty
    )

    if ($Value -isnot [array]) { throw "$Context must be an array." }
    $seen = @{}
    foreach ($item in @($Value)) {
        Assert-AdapterString -Value $item -Context "$Context item" -AllowEmpty:$AllowEmpty
        if ($seen.ContainsKey([string]$item)) { throw "$Context contains duplicate value '$item'." }
        $seen[[string]$item] = $true
    }
}

function Assert-AdapterRegularFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw "$Context must be a regular file: $Path" }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must not be a reparse point: $Path"
    }
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            throw "$Context regular-file type cannot be established on this Unix platform: $Path"
        }
        if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
            throw "$Context regular-file type cannot be established on this Linux architecture: $Path"
        }

        $nativeTypeName = 'Codex.UpstreamAdapterNative'
        if ($null -eq ($nativeTypeName -as [type])) {
            [void](Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Codex
{
    public static class UpstreamAdapterNative
    {
        private const uint S_IFMT = 0xF000;
        private const uint S_IFREG = 0x8000;

        // Linux x86_64 glibc struct stat. The adapter deliberately fails closed
        // on other Unix ABIs instead of guessing a filesystem object type.
        [StructLayout(LayoutKind.Sequential)]
        private struct LinuxStat
        {
            public ulong st_dev;
            public ulong st_ino;
            public ulong st_nlink;
            public uint st_mode;
            public uint st_uid;
            public uint st_gid;
            public int pad0;
            public ulong st_rdev;
            public long st_size;
            public long st_blksize;
            public long st_blocks;
            public long st_atime;
            public long st_atime_nsec;
            public long st_mtime;
            public long st_mtime_nsec;
            public long st_ctime;
            public long st_ctime_nsec;
            public long reserved0;
            public long reserved1;
            public long reserved2;
        }

        [DllImport("libc", EntryPoint = "lstat", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern int lstat(string path, out LinuxStat stat);

        public static bool IsRegularFile(string path)
        {
            LinuxStat stat;
            if (lstat(path, out stat) != 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "lstat failed.");
            }

            return (stat.st_mode & S_IFMT) == S_IFREG;
        }
    }
}
'@)
        }

        try { $isRegularFile = [Codex.UpstreamAdapterNative]::IsRegularFile($item.FullName) }
        catch {
            throw "$Context regular-file type could not be established: $($_.Exception.Message)"
        }
        if (-not $isRegularFile) { throw "$Context must be a regular file: $Path" }
        return $item.FullName
    }

    # PowerShell exposes the first Mode character as '-' for regular files and
    # a different type marker for directories, FIFOs, sockets and devices.
    $mode = [string]$item.Mode
    if ([string]::IsNullOrEmpty($mode) -or $mode[0] -cne '-') {
        throw "$Context must be a regular file: $Path"
    }
    return $item.FullName
}

function Skip-AdapterJsonWhitespace {
    param([Parameter(Mandatory = $true)] $State)

    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        if ($code -notin @(0x20, 0x09, 0x0A, 0x0D)) { break }
        $State.Index++
    }
}

function Add-AdapterJsonSemanticToken {
    param([Parameter(Mandatory = $true)] $State)

    $State.TokenCount++
    if ($State.TokenCount -gt $State.MaxTokens) {
        throw "JSON exceeds the maximum semantic token count of $($State.MaxTokens)."
    }
}

function Read-AdapterJsonStringValue {
    param([Parameter(Mandatory = $true)] $State)

    if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x22) {
        throw "JSON expected a string at offset $($State.Index)."
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($code -eq 0x22) { return $builder.ToString() }
        if ($code -lt 0x20) { throw "JSON string contains an unescaped control character at offset $($State.Index - 1)." }
        if ($code -ne 0x5C) {
            if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                if ($State.Index -ge $State.Text.Length) { throw 'JSON string contains an unpaired raw high surrogate.' }
                $lowCode = [int][char]$State.Text[$State.Index]
                if ($lowCode -lt 0xDC00 -or $lowCode -gt 0xDFFF) { throw 'JSON string contains an unpaired raw high surrogate.' }
                [void]$builder.Append([char]$code)
                [void]$builder.Append([char]$lowCode)
                $State.Index++
                continue
            }
            if ($code -ge 0xDC00 -and $code -le 0xDFFF) { throw 'JSON string contains an unpaired raw low surrogate.' }
            [void]$builder.Append([char]$code)
            continue
        }
        if ($State.Index -ge $State.Text.Length) { throw 'JSON string ends with an incomplete escape.' }
        $escape = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($escape -eq 0x22) { [void]$builder.Append([char]0x22); continue }
        if ($escape -eq 0x5C) { [void]$builder.Append([char]0x5C); continue }
        if ($escape -eq 0x2F) { [void]$builder.Append([char]0x2F); continue }
        if ($escape -eq 0x62) { [void]$builder.Append([char]0x08); continue }
        if ($escape -eq 0x66) { [void]$builder.Append([char]0x0C); continue }
        if ($escape -eq 0x6E) { [void]$builder.Append([char]0x0A); continue }
        if ($escape -eq 0x72) { [void]$builder.Append([char]0x0D); continue }
        if ($escape -eq 0x74) { [void]$builder.Append([char]0x09); continue }
        if ($escape -ne 0x75 -or ($State.Index + 4) -gt $State.Text.Length) {
            throw "JSON string contains an invalid escape at offset $($State.Index - 1)."
        }
        $hex = $State.Text.Substring($State.Index, 4)
        if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw "JSON string contains an invalid Unicode escape at offset $($State.Index)." }
        $unit = [Convert]::ToInt32($hex, 16)
        $State.Index += 4
        if ($unit -ge 0xD800 -and $unit -le 0xDBFF) {
            if (($State.Index + 6) -gt $State.Text.Length -or
                [int][char]$State.Text[$State.Index] -ne 0x5C -or
                [int][char]$State.Text[$State.Index + 1] -ne 0x75) {
                throw 'JSON string contains an unpaired high-surrogate escape.'
            }
            $lowHex = $State.Text.Substring($State.Index + 2, 4)
            if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw 'JSON string contains an invalid low-surrogate escape.' }
            $lowUnit = [Convert]::ToInt32($lowHex, 16)
            if ($lowUnit -lt 0xDC00 -or $lowUnit -gt 0xDFFF) { throw 'JSON string contains an unpaired high-surrogate escape.' }
            $State.Index += 6
            $scalar = 0x10000 + (($unit - 0xD800) * 0x400) + ($lowUnit - 0xDC00)
            [void]$builder.Append([char]::ConvertFromUtf32($scalar))
            continue
        }
        if ($unit -ge 0xDC00 -and $unit -le 0xDFFF) { throw 'JSON string contains an unpaired low-surrogate escape.' }
        [void]$builder.Append([char]$unit)
    }
    throw 'JSON string is unterminated.'
}

function Read-AdapterJsonValue {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][int] $Depth
    )

    if ($Depth -gt 128) { throw 'JSON exceeds the maximum nesting depth.' }
    Skip-AdapterJsonWhitespace -State $State
    Add-AdapterJsonSemanticToken -State $State
    if ($State.Index -ge $State.Text.Length) { throw 'JSON ends before a value.' }
    $code = [int][char]$State.Text[$State.Index]

    if ($code -eq 0x7B) {
        $State.Index++
        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        Skip-AdapterJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x7D) {
            $State.Index++
            return
        }
        while ($true) {
            $keyOffset = $State.Index
            Add-AdapterJsonSemanticToken -State $State
            $key = Read-AdapterJsonStringValue -State $State
            if (-not $keys.Add($key)) { throw "JSON contains a duplicate object key at offset $keyOffset." }
            Skip-AdapterJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x3A) {
                throw "JSON expected ':' after an object key at offset $keyOffset."
            }
            $State.Index++
            Read-AdapterJsonValue -State $State -Depth ($Depth + 1)
            Skip-AdapterJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'JSON object is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x7D) { return }
            if ($delimiter -ne 0x2C) { throw 'JSON object expected a comma or closing brace.' }
            Skip-AdapterJsonWhitespace -State $State
        }
    }

    if ($code -eq 0x5B) {
        $State.Index++
        Skip-AdapterJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x5D) {
            $State.Index++
            return
        }
        while ($true) {
            Read-AdapterJsonValue -State $State -Depth ($Depth + 1)
            Skip-AdapterJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'JSON array is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x5D) { return }
            if ($delimiter -ne 0x2C) { throw 'JSON array expected a comma or closing bracket.' }
            Skip-AdapterJsonWhitespace -State $State
        }
    }

    if ($code -eq 0x22) { [void](Read-AdapterJsonStringValue -State $State); return }
    $start = $State.Index
    while ($State.Index -lt $State.Text.Length) {
        $next = [int][char]$State.Text[$State.Index]
        if ($next -in @(0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D)) { break }
        $State.Index++
    }
    if ($State.Index -eq $start) { throw "JSON contains an unexpected token at offset $start." }
}

function Assert-AdapterJsonUniqueKeys {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $state = [pscustomobject]@{ Text = $Text; Index = 0; TokenCount = 0; MaxTokens = 50000 }
    Read-AdapterJsonValue -State $state -Depth 0
    Skip-AdapterJsonWhitespace -State $state
    if ($state.Index -ne $state.Text.Length) { throw "JSON contains trailing content at offset $($state.Index)." }
}

function Read-AdapterJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "$Context is missing: $Path" }
    try {
        $fullPath = Assert-AdapterRegularFile -Path $Path -Context $Context
        $item = Get-Item -Force -LiteralPath $fullPath -ErrorAction Stop
        if ($item.Length -gt 4MB) { throw "$Context exceeds the 4 MiB limit." }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = [System.IO.File]::ReadAllText($fullPath, $utf8)
        Assert-AdapterJsonUniqueKeys -Text $text -Context $Context
        return ConvertFrom-Json -InputObject $text
    }
    catch {
        throw "$Context is not valid JSON: $($_.Exception.Message)"
    }
}

function Assert-AdapterPolicy {
    param([Parameter(Mandatory = $true)] $Policy)

    $expectedFields = @(
        'schemaVersion', 'policy', 'pluginManifestPath', 'marketplacePath', 'mcpManifestPath', 'appManifestPath',
        'hooksPolicy', 'rootRelativePathPrefix', 'immutableGitShaPattern', 'acceptedMarketplaceSource',
        'allowedRemoteMcpEndpoints', 'allowedPluginManifestFields', 'requiredPluginManifestFields',
        'allowedMarketplaceRootFields', 'allowedMarketplaceEntryFields', 'allowedMarketplaceSourceFields',
        'allowedMarketplacePolicyFields', 'allowedMcpRootFields', 'allowedMcpServerFields',
        'allowedAppRootFields', 'allowedAppFields'
    )
    Assert-AdapterPropertySet -Object $Policy -Expected $expectedFields -Context 'Upstream adapter policy'
    if ($Policy.schemaVersion -isnot [int] -and $Policy.schemaVersion -isnot [long]) { throw 'Upstream adapter policy schemaVersion must be an integer.' }
    if ([int64]$Policy.schemaVersion -ne 1) { throw 'Upstream adapter policy schemaVersion must be 1.' }
    Assert-AdapterExactString -Value $Policy.policy -Expected 'upstream-interoperability-adapter-v1' -Context 'Upstream adapter policy identity'
    Assert-AdapterExactString -Value $Policy.pluginManifestPath -Expected '.codex-plugin/plugin.json' -Context 'Plugin manifest path'
    Assert-AdapterExactString -Value $Policy.marketplacePath -Expected '.agents/plugins/marketplace.json' -Context 'Marketplace path'
    Assert-AdapterExactString -Value $Policy.mcpManifestPath -Expected '.mcp.json' -Context 'MCP manifest path'
    Assert-AdapterExactString -Value $Policy.appManifestPath -Expected '.app.json' -Context 'App manifest path'
    Assert-AdapterExactString -Value $Policy.hooksPolicy -Expected 'reject' -Context 'Hooks policy'
    Assert-AdapterExactString -Value $Policy.rootRelativePathPrefix -Expected './' -Context 'Root-relative path prefix'
    Assert-AdapterExactString -Value $Policy.immutableGitShaPattern -Expected '^[0-9a-f]{40}$' -Context 'Immutable Git SHA pattern'
    Assert-AdapterExactString -Value $Policy.acceptedMarketplaceSource -Expected 'github' -Context 'Marketplace source policy'
    Assert-AdapterStringArray -Value @($Policy.allowedRemoteMcpEndpoints) -Context 'Allowed remote MCP endpoints' -AllowEmpty
    foreach ($endpoint in @($Policy.allowedRemoteMcpEndpoints)) {
        $canonicalEndpoint = Get-AdapterCanonicalEndpoint -Value $endpoint -Context 'Allowed remote MCP endpoint'
        if ([string]$endpoint -cne $canonicalEndpoint) {
            throw 'Allowed remote MCP endpoints must use canonical https URL form.'
        }
    }
    Assert-AdapterStringArray -Value @($Policy.allowedPluginManifestFields) -Context 'Plugin manifest fields'
    Assert-AdapterStringArray -Value @($Policy.requiredPluginManifestFields) -Context 'Required Plugin manifest fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMarketplaceRootFields) -Context 'Marketplace root fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMarketplaceEntryFields) -Context 'Marketplace entry fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMarketplaceSourceFields) -Context 'Marketplace source fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMarketplacePolicyFields) -Context 'Marketplace policy fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMcpRootFields) -Context 'MCP root fields'
    Assert-AdapterStringArray -Value @($Policy.allowedMcpServerFields) -Context 'MCP server fields'
    Assert-AdapterStringArray -Value @($Policy.allowedAppRootFields) -Context 'App root fields'
    Assert-AdapterStringArray -Value @($Policy.allowedAppFields) -Context 'App fields'
}

function Assert-AdapterNoReparsePoint {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must not be a reparse point: $Path"
    }
}

function Assert-AdapterPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $fullPath.StartsWith($fullRoot, $comparison) -and
        $fullPath -cne $fullRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar)) {
        throw "$Context escapes the package root: $Path"
    }
    return $fullPath
}

function Assert-AdapterNoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $fullPath = Assert-AdapterPathWithinRoot -Path $Path -Root $Root -Context $Context
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    Assert-AdapterNoReparsePoint -Path $rootFull -Context 'Package root'
    $relative = $fullPath.Substring($rootFull.Length).TrimStart(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $current = $rootFull
    foreach ($part in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Assert-AdapterNoReparsePoint -Path $current -Context $Context
        }
    }
    return $fullPath
}

function Resolve-AdapterRelativePath {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $AllowRoot
    )

    Assert-AdapterString -Value $Value -Context $Context
    if (-not $Value.StartsWith('./', [StringComparison]::Ordinal)) { throw "$Context must start with './'." }
    if ($Value.Contains('\')) { throw "$Context must use '/' separators only." }
    if ($Value -match '(^|/)\.\.(?:/|$)') { throw "$Context contains path traversal." }
    $relative = $Value.Substring(2)
    if ([string]::IsNullOrWhiteSpace($relative) -and -not $AllowRoot) { throw "$Context must name a package-relative path." }
    if ($AllowRoot -and [string]::IsNullOrEmpty($relative)) {
        $rootPath = [System.IO.Path]::GetFullPath($Root)
        Assert-AdapterNoReparsePoint -Path $rootPath -Context 'Package root'
        return $rootPath
    }
    $relativeParts = @($relative -split '/')
    foreach ($part in $relativeParts) {
        if ($part -match '[\x00-\x1F\x7F]' -or $part -ceq '' -or $part -ceq '.' -or $part -ceq '..' -or
            $part.Contains(':') -or $part.EndsWith('.') -or $part.EndsWith(' ')) {
            throw "$Context contains a non-portable or unsafe path segment."
        }
    }
    $candidate = if ([string]::IsNullOrWhiteSpace($relative)) {
        [System.IO.Path]::GetFullPath($Root)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $Root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    }
    $fullPath = Assert-AdapterPathWithinRoot -Path $candidate -Root $Root -Context $Context
    $current = [System.IO.Path]::GetFullPath($Root)
    Assert-AdapterNoReparsePoint -Path $current -Context 'Package root'
    foreach ($part in $relativeParts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) { Assert-AdapterNoReparsePoint -Path $current -Context $Context }
    }
    return $fullPath
}

function Assert-AdapterSafeName {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)
    Assert-AdapterString -Value $Value -Context $Context
    if ([string]$Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "$Context contains an unsafe identity." }
}

function Get-AdapterCanonicalEndpoint {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-AdapterString -Value $Value -Context $Context
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Value, [UriKind]::Absolute, [ref]$uri) -or
        [string]$uri.Scheme -cne 'https' -or
        [string]::IsNullOrEmpty([string]$uri.Host) -or
        -not [string]::IsNullOrEmpty([string]$uri.UserInfo) -or
        -not [string]::IsNullOrEmpty([string]$uri.Query) -or
        -not [string]::IsNullOrEmpty([string]$uri.Fragment)) {
        throw "$Context must be an exact canonical https endpoint without userinfo, query, or fragment."
    }
    $path = [string]$uri.AbsolutePath
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }
    if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
    return ('https://{0}{1}' -f [string]$uri.Authority.ToLowerInvariant(), $path)
}

function Assert-AdapterMcpServers {
    param(
        [Parameter(Mandatory = $true)] $Servers,
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Servers -or $Servers -is [string] -or $Servers -is [array] -or $null -eq $Servers.PSObject) {
        throw "$Context must be an object."
    }
    foreach ($serverProperty in @($Servers.PSObject.Properties)) {
        Assert-AdapterSafeName -Value $serverProperty.Name -Context "$Context server name"
        $server = $serverProperty.Value
        Assert-AdapterPropertySet -Object $server -Expected @($Policy.allowedMcpServerFields) -Context "$Context server '$($serverProperty.Name)'"
        $hasCommand = $null -ne (Get-AdapterProperty -Object $server -Name 'command')
        $hasUrl = $null -ne (Get-AdapterProperty -Object $server -Name 'url')
        if (($hasCommand -and $hasUrl) -or (-not $hasCommand -and -not $hasUrl)) {
            throw "$Context server '$($serverProperty.Name)' must declare exactly one command or url."
        }
        if ($hasCommand) {
            $commandPath = Resolve-AdapterRelativePath -Value $server.command -Root $Root -Context "$Context server '$($serverProperty.Name)' command"
            [void](Assert-AdapterRegularFile -Path $commandPath -Context "$Context server '$($serverProperty.Name)' command")
        }
        if ($hasUrl) {
            $canonicalEndpoint = Get-AdapterCanonicalEndpoint -Value $server.url -Context "$Context server '$($serverProperty.Name)' url"
            if (@($Policy.allowedRemoteMcpEndpoints) -cnotcontains $canonicalEndpoint) {
                throw "BLOCK: $Context server '$($serverProperty.Name)' uses an unapproved endpoint."
            }
        }
        $args = Get-AdapterProperty -Object $server -Name 'args'
        if ($null -ne $args) { Assert-AdapterStringArray -Value $args -Context "$Context server '$($serverProperty.Name)' args" -AllowEmpty }
    }
}

function Assert-AdapterApps {
    param(
        [Parameter(Mandatory = $true)] $Apps,
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Apps -isnot [array]) { throw "$Context must be an array." }
    foreach ($app in @($Apps)) {
        Assert-AdapterPropertySet -Object $app -Expected @($Policy.allowedAppFields) -Context "$Context entry"
        Assert-AdapterSafeName -Value $app.name -Context "$Context name"
        Assert-AdapterSafeName -Value $app.mcpServer -Context "$Context mcpServer"
    }
}

function Test-AdapterOptionalFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    [void](Assert-AdapterRegularFile -Path $Path -Context 'Optional adapter manifest')
    return $true
}

function Invoke-UpstreamAdapterValidation {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)] $Policy
    )

    $rootItem = Get-Item -Force -LiteralPath $Root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Package root must be a non-reparse directory.'
    }
    $rootFull = [System.IO.Path]::GetFullPath($rootItem.FullName)
    $surfaces = [System.Collections.Generic.List[string]]::new()

    $hooksPath = Join-Path $rootFull 'hooks'
    if (Test-Path -LiteralPath $hooksPath) { throw 'BLOCK: Plugin hooks are not adopted by Standard v1.' }

    $pluginPath = Join-Path $rootFull $Policy.pluginManifestPath
    if (Test-AdapterOptionalFile -Path $pluginPath) {
        $surfaces.Add('plugin')
        [void](Assert-AdapterNoReparsePath -Path $pluginPath -Root $rootFull -Context 'Plugin manifest')
        $plugin = Read-AdapterJson -Path $pluginPath -Context 'Plugin manifest'
        Assert-AdapterPropertySet -Object $plugin -Expected @($Policy.allowedPluginManifestFields) -Context 'Plugin manifest'
        foreach ($name in @($Policy.requiredPluginManifestFields)) {
            if ($null -eq (Get-AdapterProperty -Object $plugin -Name $name)) { throw "Plugin manifest is missing required field '$name'." }
        }
        Assert-AdapterSafeName -Value $plugin.name -Context 'Plugin manifest name'
        foreach ($name in @('description', 'version')) {
            $value = Get-AdapterProperty -Object $plugin -Name $name
            if ($null -ne $value) { Assert-AdapterString -Value $value -Context "Plugin manifest $name" }
        }
        $skills = Get-AdapterProperty -Object $plugin -Name 'skills'
        if ($null -ne $skills) {
            Assert-AdapterStringArray -Value $skills -Context 'Plugin manifest skills'
            foreach ($skillPathValue in @($skills)) {
                $skillPath = Resolve-AdapterRelativePath -Value $skillPathValue -Root $rootFull -Context 'Plugin manifest skill path'
                if (-not (Test-Path -LiteralPath $skillPath -PathType Container)) { throw "Plugin manifest skill path is missing: $skillPathValue" }
                $skillMdPath = Join-Path $skillPath 'SKILL.md'
                if (-not (Test-Path -LiteralPath $skillMdPath)) { throw "BLOCK: Plugin Skill is missing SKILL.md: $skillPathValue" }
                [void](Assert-AdapterRegularFile -Path $skillMdPath -Context 'Plugin Skill SKILL.md')
            }
        }
        $pluginMcp = Get-AdapterProperty -Object $plugin -Name 'mcpServers'
        if ($null -ne $pluginMcp) { Assert-AdapterMcpServers -Servers $pluginMcp -Policy $Policy -Root $rootFull -Context 'Plugin manifest MCP servers' }
        $pluginApps = Get-AdapterProperty -Object $plugin -Name 'apps'
        if ($null -ne $pluginApps) { Assert-AdapterApps -Apps $pluginApps -Policy $Policy -Context 'Plugin manifest apps' }
    }

    $mcpPath = Join-Path $rootFull $Policy.mcpManifestPath
    if (Test-AdapterOptionalFile -Path $mcpPath) {
        $surfaces.Add('mcp')
        [void](Assert-AdapterNoReparsePath -Path $mcpPath -Root $rootFull -Context 'MCP manifest')
        $mcp = Read-AdapterJson -Path $mcpPath -Context 'MCP manifest'
        Assert-AdapterPropertySet -Object $mcp -Expected @($Policy.allowedMcpRootFields) -Context 'MCP manifest'
        $servers = Get-AdapterProperty -Object $mcp -Name 'mcpServers'
        if ($null -eq $servers) { throw 'MCP manifest is missing mcpServers.' }
        Assert-AdapterMcpServers -Servers $servers -Policy $Policy -Root $rootFull -Context 'MCP manifest'
    }

    $appPath = Join-Path $rootFull $Policy.appManifestPath
    if (Test-AdapterOptionalFile -Path $appPath) {
        $surfaces.Add('app')
        [void](Assert-AdapterNoReparsePath -Path $appPath -Root $rootFull -Context 'App manifest')
        $app = Read-AdapterJson -Path $appPath -Context 'App manifest'
        Assert-AdapterPropertySet -Object $app -Expected @($Policy.allowedAppRootFields) -Context 'App manifest'
        $apps = Get-AdapterProperty -Object $app -Name 'apps'
        if ($null -eq $apps) { throw 'App manifest is missing apps.' }
        Assert-AdapterApps -Apps $apps -Policy $Policy -Context 'App manifest'
    }

    $marketplacePath = Join-Path $rootFull $Policy.marketplacePath
    if (Test-AdapterOptionalFile -Path $marketplacePath) {
        $surfaces.Add('marketplace')
        [void](Assert-AdapterNoReparsePath -Path $marketplacePath -Root $rootFull -Context 'Marketplace manifest')
        $marketplace = Read-AdapterJson -Path $marketplacePath -Context 'Marketplace manifest'
        Assert-AdapterPropertySet -Object $marketplace -Expected @($Policy.allowedMarketplaceRootFields) -Context 'Marketplace manifest'
        $plugins = Get-AdapterProperty -Object $marketplace -Name 'plugins'
        if ($plugins -isnot [array] -or @($plugins).Count -eq 0) { throw 'Marketplace manifest plugins must be a non-empty array.' }
        $seenMarketplaceNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($entry in @($plugins)) {
            Assert-AdapterPropertySet -Object $entry -Expected @($Policy.allowedMarketplaceEntryFields) -Context 'Marketplace entry'
            Assert-AdapterSafeName -Value $entry.name -Context 'Marketplace entry name'
            if (-not $seenMarketplaceNames.Add([string]$entry.name)) { throw "Marketplace manifest contains duplicate plugin identity '$($entry.name)'." }
            $source = Get-AdapterProperty -Object $entry -Name 'source'
            if ($null -eq $source) { throw 'Marketplace entry is missing source.' }
            Assert-AdapterPropertySet -Object $source -Expected @($Policy.allowedMarketplaceSourceFields) -Context 'Marketplace source'
            Assert-AdapterExactString -Value $source.source -Expected $Policy.acceptedMarketplaceSource -Context 'Marketplace source type'
            Assert-AdapterString -Value $source.repo -Context 'Marketplace Git repository'
            if ([string]$source.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Marketplace Git repository must be owner/name.' }
            Resolve-AdapterRelativePath -Value $source.path -Root $rootFull -Context 'Marketplace source.path' -AllowRoot | Out-Null
            Assert-AdapterString -Value $source.sha -Context 'Marketplace source.sha'
            if ([string]$source.sha -cnotmatch $Policy.immutableGitShaPattern) { throw 'BLOCK: Marketplace source must bind an immutable Git SHA.' }
            $ref = Get-AdapterProperty -Object $source -Name 'ref'
            if ($null -ne $ref) {
                Assert-AdapterString -Value $ref -Context 'Marketplace source.ref'
                if ([string]$ref -cne [string]$source.sha) {
                    throw 'BLOCK: Marketplace source.ref must be omitted or equal the immutable Git SHA.'
                }
            }
            foreach ($name in @('description', 'category', 'interface')) {
                $value = Get-AdapterProperty -Object $entry -Name $name
                if ($null -ne $value) { Assert-AdapterString -Value $value -Context "Marketplace entry $name" }
            }
            $entryPolicy = Get-AdapterProperty -Object $entry -Name 'policy'
            if ($null -ne $entryPolicy) {
                Assert-AdapterPropertySet -Object $entryPolicy -Expected @($Policy.allowedMarketplacePolicyFields) -Context 'Marketplace entry policy'
                foreach ($name in @($Policy.allowedMarketplacePolicyFields)) {
                    $value = Get-AdapterProperty -Object $entryPolicy -Name $name
                    if ($null -ne $value) { Assert-AdapterString -Value $value -Context "Marketplace policy $name" }
                }
            }
        }
    }

    $status = if ($surfaces.Count -eq 0) { 'not-applicable' } else { 'passed' }
    return [ordered]@{
        schemaVersion = 1
        policy = [string]$Policy.policy
        status = $status
        packageRoot = $rootFull
        surfaces = @($surfaces)
        decision = if ($status -eq 'passed') { 'PASS' } else { 'NOT_APPLICABLE' }
    }
}

try {
    $policy = Read-AdapterJson -Path ([System.IO.Path]::GetFullPath($PolicyPath)) -Context 'Upstream adapter policy'
    Assert-AdapterPolicy -Policy $policy
    $result = Invoke-UpstreamAdapterValidation -Root ([System.IO.Path]::GetFullPath($PackageRoot)) -Policy $policy
    $json = $result | ConvertTo-Json -Depth 20
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $parent = Split-Path -Parent $OutputPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    Write-Output $json
}
catch {
    throw "BLOCK: upstream adapter validation failed: $($_.Exception.Message)"
}

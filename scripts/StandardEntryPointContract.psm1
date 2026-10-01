Set-StrictMode -Version 2.0

$script:StandardEntryPointInputRoots = @('scripts', 'tests', 'docs/standards', '.github/workflows')
$script:StandardEntryPointBindingProperties = @(
    'schemaVersion', 'entryId', 'eventName', 'candidateRevision', 'authorityRevision',
    'runtime', 'configSha256', 'requiredChecks', 'resultArtifact', 'contentMode', 'inputFileManifest'
)
$script:StandardEntryPointResultProperties = @('schemaVersion', 'binding', 'status', 'executed', 'releaseEligible', 'checks')
$script:StandardEntryPointManifestProperties = @('role', 'path', 'sha256')
$script:StandardEntryPointCheckProperties = @('name', 'status', 'executed', 'exitCode')
$script:StandardEntryPointJsonLimit = 16777216
$script:StandardEntryLastVerifiedBinding = $null

function Get-StandardEntryPointRuntime {
    $os = $null
    if ([string]$PSVersionTable.PSEdition -eq 'Desktop') {
        $os = 'windows'
    }
    else {
        $isWindowsVariable = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
        $isLinuxVariable = Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue
        $isMacVariable = Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $isWindowsVariable -and [bool]$isWindowsVariable) { $os = 'windows' }
        elseif ($null -ne $isLinuxVariable -and [bool]$isLinuxVariable) { $os = 'linux' }
        elseif ($null -ne $isMacVariable -and [bool]$isMacVariable) { $os = 'macos' }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $os = 'windows' }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { $os = 'linux' }
    }

    if ($os -notin @('windows', 'linux', 'macos')) {
        throw 'STANDARD_ENTRY_INVALID|The current operating system cannot be identified.'
    }
    $edition = [string]$PSVersionTable.PSEdition
    if ($edition -notin @('Core', 'Desktop')) {
        throw 'STANDARD_ENTRY_INVALID|The current PowerShell edition cannot be identified.'
    }
    $version = [string]$PSVersionTable.PSVersion.ToString()
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'STANDARD_ENTRY_INVALID|The current PowerShell version cannot be identified.'
    }

    return [pscustomobject][ordered]@{
        os = $os
        psEdition = $edition
        psVersion = $version
    }
}

function Get-SEPObjectPropertyNames {
    param([Parameter(Mandatory = $true)] $Object, [Parameter(Mandatory = $true)] [string] $Context)

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType] -or $Object -is [array]) {
        throw "STANDARD_ENTRY_INVALID|$Context must be an object."
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $names = @()
        foreach ($key in $Object.Keys) { $names += [string]$key }
        return $names
    }
    if ($Object -isnot [pscustomobject]) {
        throw "STANDARD_ENTRY_INVALID|$Context must be a typed object."
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-SEPExactProperties {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $actual = @(Get-SEPObjectPropertyNames -Object $Object -Context $Context)
    if ($actual.Count -ne $Expected.Count) {
        throw "STANDARD_ENTRY_INVALID|$Context has an unexpected property count."
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { throw "STANDARD_ENTRY_INVALID|$Context is missing exact property '$name'." }
    }
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "STANDARD_ENTRY_INVALID|$Context has unknown property '$name'." }
    }
}

function Get-SEPExactProperty {
    param([Parameter(Mandatory = $true)] $Object, [Parameter(Mandatory = $true)] [string] $Name)

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ceq $Name) {
                $value = $Object[$key]
                if ($value -is [array]) { return ,$value }
                return $value
            }
        }
        return $null
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]$property.Name -ceq $Name) {
            $value = $property.Value
            if ($value -is [array]) { return ,$value }
            return $value
        }
    }
    return $null
}

function Assert-SEPString {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Context,
        [string] $Pattern,
        [switch] $AllowEmpty
    )

    if ($Value -isnot [string]) { throw "STANDARD_ENTRY_INVALID|$Context must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "STANDARD_ENTRY_INVALID|$Context must be a non-empty string."
    }
    if ($null -ne $Pattern) {
        $regex = New-Object Text.RegularExpressions.Regex($Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(2))
        if (-not $regex.IsMatch([string]$Value)) { throw "STANDARD_ENTRY_INVALID|$Context has an invalid value." }
    }
    return [string]$Value
}

function Assert-SEPInteger {
    param([AllowNull()] $Value, [Parameter(Mandatory = $true)] [string] $Context)

    if ($Value -is [bool] -or
        ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and
         $Value -isnot [int32] -and $Value -isnot [uint32] -and $Value -isnot [int64] -and $Value -isnot [uint64])) {
        throw "STANDARD_ENTRY_INVALID|$Context must be an integer."
    }
    return [long]$Value
}

function Assert-SEPSafeRelativePath {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Context,
        [switch] $JsonFile
    )

    $path = Assert-SEPString -Value $Value -Context $Context
    if ($path.StartsWith('/', [StringComparison]::Ordinal) -or
        $path.Contains('\') -or $path.Contains(':') -or
        $path -match '[\u0000-\u001f\u007f<>:"|?*]') {
        throw "STANDARD_ENTRY_INVALID|$Context must be a safe slash-relative path."
    }
    $segments = $path.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or $segment.EndsWith(' ', [StringComparison]::Ordinal)) {
            throw "STANDARD_ENTRY_INVALID|$Context contains an unsafe path segment."
        }
    }
    if ($JsonFile -and -not $path.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        throw "STANDARD_ENTRY_INVALID|$Context must identify a JSON file."
    }
    return $path
}

function Test-SEPInputPathInScope {
    param([string] $Path)
    foreach ($scope in $script:StandardEntryPointInputRoots) {
        if ($Path.StartsWith($scope + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-SEPUnambiguousJson {
    param([Parameter(Mandatory = $true)] [string] $Json, [Parameter(Mandatory = $true)] [string] $Context)

    $tokenPattern = '\G\s*(?:"(?:\\.|[^"\\])*"|[{}\[\],:]|[^{}\[\],:\s]+)'
    $tokenRegex = New-Object Text.RegularExpressions.Regex($tokenPattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2))
    $stack = New-Object System.Collections.ArrayList
    [void]$stack.Add([pscustomobject]@{ kind = 'root'; mode = 'value'; seen = $null })
    $position = 0

    try {
        while ($position -lt $Json.Length) {
            $match = $tokenRegex.Match($Json, $position)
            if (-not $match.Success -or $match.Index -ne $position) {
                if ([string]::IsNullOrWhiteSpace($Json.Substring($position))) { break }
                throw "STANDARD_ENTRY_INVALID|$Context JSON token is invalid."
            }
            $token = $match.Value.TrimStart()
            $position += $match.Length
            $frame = $stack[$stack.Count - 1]

            if ($token -ceq '}' -or $token -ceq ']') {
                if ($frame.kind -ceq 'root' -or
                    ($token -ceq '}' -and $frame.kind -cne 'object') -or
                    ($token -ceq ']' -and $frame.kind -cne 'array') -or
                    $frame.mode -notin @('keyOrEnd', 'valueOrEnd', 'commaOrEnd')) {
                    throw "STANDARD_ENTRY_INVALID|$Context JSON structure is invalid."
                }
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            if ($token -ceq ',') {
                if ($frame.mode -cne 'commaOrEnd') { throw "STANDARD_ENTRY_INVALID|$Context JSON comma is invalid." }
                $frame.mode = if ($frame.kind -ceq 'object') { 'key' } else { 'value' }
                continue
            }
            if ($token -ceq ':') {
                if ($frame.kind -cne 'object' -or $frame.mode -cne 'colon') { throw "STANDARD_ENTRY_INVALID|$Context JSON colon is invalid." }
                $frame.mode = 'value'
                continue
            }
            if ($frame.kind -ceq 'object' -and $frame.mode -in @('key', 'keyOrEnd')) {
                if (-not $token.StartsWith('"', [StringComparison]::Ordinal)) { throw "STANDARD_ENTRY_INVALID|$Context JSON key is invalid." }
                try {
                    $decoded = ConvertFrom-Json -InputObject ('{"key":' + $token + '}') -ErrorAction Stop
                    $key = [string]$decoded.key
                }
                catch { throw "STANDARD_ENTRY_INVALID|$Context JSON key is invalid." }
                if (-not $frame.seen.Add($key)) { throw "STANDARD_ENTRY_INVALID|$Context has duplicate decoded JSON property names." }
                $frame.mode = 'colon'
                continue
            }
            if ($frame.mode -cne 'value' -and $frame.mode -cne 'valueOrEnd') {
                throw "STANDARD_ENTRY_INVALID|$Context JSON value is invalid."
            }
            $frame.mode = if ($frame.kind -ceq 'root') { 'done' } else { 'commaOrEnd' }
            if ($token -ceq '{') {
                [void]$stack.Add([pscustomobject]@{ kind = 'object'; mode = 'keyOrEnd'; seen = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)) })
            }
            elseif ($token -ceq '[') {
                [void]$stack.Add([pscustomobject]@{ kind = 'array'; mode = 'valueOrEnd'; seen = $null })
            }
        }
    }
    catch {
        if ($_.Exception.Message -like 'STANDARD_ENTRY_INVALID|*') { throw }
        throw "STANDARD_ENTRY_INVALID|$Context JSON token scan failed."
    }

    if ($stack.Count -ne 1 -or $stack[0].mode -cne 'done') {
        throw "STANDARD_ENTRY_INVALID|$Context JSON is incomplete."
    }
}

function Assert-SEPPathHasNoReparsePoints {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $Context)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($pathRoot)) { throw "STANDARD_ENTRY_INVALID|$Context path is not absolute." }
    $remainder = $fullPath.Substring($pathRoot.Length)
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parts = @($remainder.Split($separators, [StringSplitOptions]::RemoveEmptyEntries))
    $current = $pathRoot
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { throw "STANDARD_ENTRY_INVALID|$Context path component is missing." }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "STANDARD_ENTRY_INVALID|$Context path contains a reparse point."
        }
    }
    return $fullPath
}

function Read-SEPJsonFile {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $Context)

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        [void](Assert-SEPPathHasNoReparsePoints -Path $fullPath -Context $Context)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "STANDARD_ENTRY_MISSING|$Context JSON file is missing." }
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { throw "STANDARD_ENTRY_INVALID|$Context must be a regular JSON file." }
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        if ($bytes.Length -lt 2 -or $bytes.Length -gt $script:StandardEntryPointJsonLimit) {
            throw "STANDARD_ENTRY_INVALID|$Context JSON size is outside the allowed range."
        }
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $json = $encoding.GetString($bytes)
        Assert-SEPUnambiguousJson -Json $json -Context $Context
        $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($null -eq $value -or $value -is [array]) { throw "STANDARD_ENTRY_INVALID|$Context must contain one JSON object." }
        return [pscustomobject]@{ value = $value; sha256 = (Get-SEPByteSha256 -Bytes $bytes) }
    }
    catch {
        if ($_.Exception.Message -like 'STANDARD_ENTRY_*|*') { throw }
        throw "STANDARD_ENTRY_INVALID|$Context is not strict, unambiguous UTF-8 JSON."
    }
}

function Get-SEPByteSha256 {
    param([Parameter(Mandatory = $true)] [byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($Bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Invoke-SEPGit {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string[]] $Arguments)

    $safeRoot = $Root.Replace('\', '/')
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # PS5.1 promotes native stderr to an error under Stop, even when Git exits successfully.
        $ErrorActionPreference = 'Continue'
        $output = @(& git -c "safe.directory=$safeRoot" -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    return [pscustomobject]@{ exitCode = [int]$exitCode; output = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ })) }
}

function Get-SEPHeadRevision {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string] $Role)

    $result = Invoke-SEPGit -Root $Root -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
    if ($result.exitCode -ne 0) { throw "STANDARD_ENTRY_BLOCKED|$Role root is not a readable regular Git checkout: $($result.output)" }
    $revision = $result.output.Trim().ToLowerInvariant()
    if ($revision -notmatch '^[0-9a-f]{40}$') { throw "STANDARD_ENTRY_BLOCKED|$Role HEAD is not a full commit revision." }
    return $revision
}

function Get-SEPTrackedInputFiles {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string] $Role)

    $arguments = @('ls-files', '--stage', '-z', '--') + @($script:StandardEntryPointInputRoots)
    $result = Invoke-SEPGit -Root $Root -Arguments $arguments
    if ($result.exitCode -ne 0) { throw "STANDARD_ENTRY_BLOCKED|Unable to read $Role Git index: $($result.output)" }

    $tracked = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $casePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $records = [string]$result.output
    foreach ($record in $records.Split([char]0)) {
        if ([string]::IsNullOrEmpty($record)) { continue }
        $separator = $record.IndexOf([char]9)
        if ($separator -lt 0) { throw "STANDARD_ENTRY_BLOCKED|$Role Git index returned an invalid path record." }
        $metadata = $record.Substring(0, $separator).Split(' ')
        $path = $record.Substring($separator + 1)
        if ($metadata.Count -ne 3 -or $metadata[0] -notin @('100644', '100755') -or $metadata[1] -notmatch '^(?!0+$)[0-9a-f]{40}(?:[0-9a-f]{24})?$' -or $metadata[2] -cne '0') {
            throw "STANDARD_ENTRY_INVALID|$Role input '$path' is not a regular tracked file."
        }
        $path = Assert-SEPSafeRelativePath -Value $path -Context "$Role tracked input path"
        if (-not (Test-SEPInputPathInScope -Path $path)) { throw "STANDARD_ENTRY_INVALID|$Role tracked input escapes the declared inventory roots." }
        if (-not $casePaths.Add($path)) { throw "STANDARD_ENTRY_INVALID|$Role Git index has a case-insensitive input path collision." }
        $tracked.Add($path, $metadata[0])
    }
    return $tracked
}

function Get-SEPRegularInputFiles {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string] $Role)

    $actual = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $casePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $rootPrefix = $Root.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq [char]92) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

    foreach ($scope in $script:StandardEntryPointInputRoots) {
        $scopePath = Join-Path $Root ($scope.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $scopePath)) { continue }
        $scopeItem = Get-Item -LiteralPath $scopePath -Force -ErrorAction Stop
        if (-not $scopeItem.PSIsContainer) { throw "STANDARD_ENTRY_INVALID|$Role inventory root '$scope' must be a directory." }
        if (($scopeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "STANDARD_ENTRY_INVALID|$Role inventory root '$scope' is a reparse point."
        }

        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($scopePath)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($entry in [IO.Directory]::GetFileSystemEntries($directory)) {
                $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "STANDARD_ENTRY_INVALID|$Role input path '$entry' is a reparse point."
                }
                if ($item.PSIsContainer) {
                    if ([string]$item.Name -ceq '.git') { throw "STANDARD_ENTRY_INVALID|$Role input contains nested Git metadata." }
                    $pending.Push($item.FullName)
                    continue
                }
                if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
                    ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
                    throw "STANDARD_ENTRY_INVALID|$Role input path '$entry' is not a regular file."
                }
                $full = [IO.Path]::GetFullPath($item.FullName)
                if (-not $full.StartsWith($rootPrefix, $comparison)) { throw "STANDARD_ENTRY_INVALID|$Role input escaped its root." }
                $relative = $full.Substring($rootPrefix.Length).Replace('\', '/')
                $relative = Assert-SEPSafeRelativePath -Value $relative -Context "$Role input path"
                if (-not (Test-SEPInputPathInScope -Path $relative)) { throw "STANDARD_ENTRY_INVALID|$Role input escaped the declared inventory roots." }
                if (-not $casePaths.Add($relative)) { throw "STANDARD_ENTRY_INVALID|$Role has a case-insensitive input path collision." }
                $actual.Add($relative, $full)
            }
        }
    }
    return $actual
}

function Get-SEPInputInventory {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] [string] $Role)

    $tracked = Get-SEPTrackedInputFiles -Root $Root -Role $Role
    $actual = Get-SEPRegularInputFiles -Root $Root -Role $Role
    foreach ($path in $tracked.Keys) {
        if (-not $actual.ContainsKey($path)) { throw "STANDARD_ENTRY_BLOCKED|$Role tracked input '$path' is missing from the checkout." }
    }

    $entries = @()
    foreach ($path in $actual.Keys) {
        $bytes = [IO.File]::ReadAllBytes($actual[$path])
        $entries += [pscustomobject][ordered]@{
            role = $Role
            path = $path
            sha256 = Get-SEPByteSha256 -Bytes $bytes
        }
    }
    return [pscustomobject]@{
        entries = @($entries)
        trackedPaths = @($tracked.Keys)
        filePaths = @($actual.Keys)
    }
}

function Test-SEPInventoryEqual {
    param([Parameter(Mandatory = $true)] $First, [Parameter(Mandatory = $true)] $Second)

    $left = @($First.entries)
    $right = @($Second.entries)
    if ($left.Count -ne $right.Count) { return $false }
    for ($index = 0; $index -lt $left.Count; $index++) {
        if ([string]$left[$index].path -cne [string]$right[$index].path -or
            [string]$left[$index].sha256 -cne [string]$right[$index].sha256) { return $false }
    }
    return $true
}

function Test-SEPInputTreeDirty {
    param([Parameter(Mandatory = $true)] [string] $Root, [Parameter(Mandatory = $true)] $Inventory)

    $diffArguments = @('diff', '--quiet', 'HEAD', '--') + @($script:StandardEntryPointInputRoots)
    $diff = Invoke-SEPGit -Root $Root -Arguments $diffArguments
    if ($diff.exitCode -notin @(0, 1)) { throw "STANDARD_ENTRY_BLOCKED|Unable to compare $Root inputs with HEAD: $($diff.output)" }
    if ($diff.exitCode -eq 1) { return $true }

    $tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in @($Inventory.trackedPaths)) { [void]$tracked.Add([string]$path) }
    foreach ($path in @($Inventory.filePaths)) {
        if (-not $tracked.Contains([string]$path)) { return $true }
    }
    return $false
}

function Get-SEPManifestSortKey {
    param([Parameter(Mandatory = $true)] $Entry)
    return ([string]$Entry.role + [char]0 + [string]$Entry.path)
}

function Sort-SEPManifestEntries {
    param([Parameter(Mandatory = $true)] [object[]] $Entries)

    $byKey = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($entry in $Entries) { $byKey.Add((Get-SEPManifestSortKey -Entry $entry), $entry) }
    $keys = [string[]]@($byKey.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $sorted = @()
    foreach ($key in $keys) { $sorted += $byKey[$key] }
    return ,$sorted
}

function Assert-SEPBindingObject {
    param([Parameter(Mandatory = $true)] $Binding)

    Assert-SEPExactProperties -Object $Binding -Expected $script:StandardEntryPointBindingProperties -Context 'binding'
    if ((Assert-SEPInteger -Value (Get-SEPExactProperty -Object $Binding -Name 'schemaVersion') -Context 'binding.schemaVersion') -ne 1) {
        throw 'STANDARD_ENTRY_INVALID|binding.schemaVersion must be 1.'
    }
    [void](Assert-SEPString -Value (Get-SEPExactProperty -Object $Binding -Name 'entryId') -Context 'binding.entryId' -Pattern '^[a-z0-9]+(?:[.-][a-z0-9]+)*$')
    $eventName = Assert-SEPString -Value (Get-SEPExactProperty -Object $Binding -Name 'eventName') -Context 'binding.eventName'
    if ($eventName -cnotin @('pull_request', 'push', 'workflow_dispatch', 'local-contract')) {
        throw 'STANDARD_ENTRY_INVALID|binding.eventName is unsupported.'
    }
    foreach ($revisionName in @('candidateRevision', 'authorityRevision')) {
        [void](Assert-SEPString -Value (Get-SEPExactProperty -Object $Binding -Name $revisionName) -Context "binding.$revisionName" -Pattern '^[0-9a-f]{40}$')
    }

    $runtime = Get-SEPExactProperty -Object $Binding -Name 'runtime'
    Assert-SEPExactProperties -Object $runtime -Expected @('os', 'psEdition', 'psVersion') -Context 'binding.runtime'
    $os = Assert-SEPString -Value (Get-SEPExactProperty -Object $runtime -Name 'os') -Context 'binding.runtime.os'
    $edition = Assert-SEPString -Value (Get-SEPExactProperty -Object $runtime -Name 'psEdition') -Context 'binding.runtime.psEdition'
    $version = Assert-SEPString -Value (Get-SEPExactProperty -Object $runtime -Name 'psVersion') -Context 'binding.runtime.psVersion'
    if ($os -cnotin @('windows', 'linux', 'macos') -or $edition -cnotin @('Core', 'Desktop')) {
        throw 'STANDARD_ENTRY_INVALID|binding.runtime contains an unsupported value.'
    }
    $actualRuntime = Get-StandardEntryPointRuntime
    if ($os -cne $actualRuntime.os -or $edition -cne $actualRuntime.psEdition -or $version -cne $actualRuntime.psVersion) {
        throw 'STANDARD_ENTRY_BLOCKED|binding.runtime does not match the current process runtime.'
    }

    $configSha = Assert-SEPString -Value (Get-SEPExactProperty -Object $Binding -Name 'configSha256') -Context 'binding.configSha256' -Pattern '^[0-9a-f]{64}$'
    $requiredChecks = Get-SEPExactProperty -Object $Binding -Name 'requiredChecks'
    if ($requiredChecks -isnot [array] -or @($requiredChecks).Count -eq 0) {
        throw 'STANDARD_ENTRY_INVALID|binding.requiredChecks must be a non-empty array.'
    }
    $checkSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $previousCheck = $null
    foreach ($check in @($requiredChecks)) {
        [void](Assert-SEPString -Value $check -Context 'binding.requiredChecks item')
        if (-not $checkSet.Add([string]$check)) { throw 'STANDARD_ENTRY_INVALID|binding.requiredChecks contains a duplicate.' }
        if ($null -ne $previousCheck -and [StringComparer]::Ordinal.Compare([string]$previousCheck, [string]$check) -gt 0) {
            throw 'STANDARD_ENTRY_INVALID|binding.requiredChecks must be sorted by ordinal name.'
        }
        $previousCheck = [string]$check
    }

    $resultArtifact = Assert-SEPSafeRelativePath -Value (Get-SEPExactProperty -Object $Binding -Name 'resultArtifact') -Context 'binding.resultArtifact' -JsonFile
    $contentMode = Assert-SEPString -Value (Get-SEPExactProperty -Object $Binding -Name 'contentMode') -Context 'binding.contentMode'
    if ($contentMode -cnotin @('immutable', 'development')) { throw 'STANDARD_ENTRY_INVALID|binding.contentMode is unsupported.' }

    $manifest = Get-SEPExactProperty -Object $Binding -Name 'inputFileManifest'
    if ($manifest -isnot [array] -or @($manifest).Count -lt 2) {
        throw 'STANDARD_ENTRY_INVALID|binding.inputFileManifest must contain both input roles.'
    }
    $roles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $manifestEntries = @()
    $previousKey = $null
    foreach ($entry in @($manifest)) {
        Assert-SEPExactProperties -Object $entry -Expected $script:StandardEntryPointManifestProperties -Context 'binding.inputFileManifest entry'
        $role = Assert-SEPString -Value (Get-SEPExactProperty -Object $entry -Name 'role') -Context 'manifest.role'
        if ($role -cnotin @('candidate', 'authority')) { throw 'STANDARD_ENTRY_INVALID|manifest.role is unsupported.' }
        [void]$roles.Add($role)
        $path = Assert-SEPSafeRelativePath -Value (Get-SEPExactProperty -Object $entry -Name 'path') -Context 'manifest.path'
        if (-not (Test-SEPInputPathInScope -Path $path)) { throw 'STANDARD_ENTRY_INVALID|manifest.path is outside the declared input roots.' }
        [void](Assert-SEPString -Value (Get-SEPExactProperty -Object $entry -Name 'sha256') -Context 'manifest.sha256' -Pattern '^[0-9a-f]{64}$')
        $uniqueKey = $role + [char]0 + $path
        if (-not $seenPaths.Add($uniqueKey)) { throw 'STANDARD_ENTRY_INVALID|manifest has a duplicate role/path pair.' }
        if ($null -ne $previousKey -and [StringComparer]::Ordinal.Compare([string]$previousKey, $uniqueKey) -gt 0) {
            throw 'STANDARD_ENTRY_INVALID|inputFileManifest must be sorted by ordinal role and path.'
        }
        $previousKey = $uniqueKey
        $manifestEntries += $entry
    }
    if (-not $roles.Contains('candidate') -or -not $roles.Contains('authority')) {
        throw 'STANDARD_ENTRY_INVALID|inputFileManifest must include candidate and authority entries.'
    }
    $configEntry = @($manifestEntries | Where-Object { $_.role -ceq 'authority' -and $_.path -ceq 'docs/standards/validation-security-gate.json' })
    if ($configEntry.Count -ne 1 -or [string]$configEntry[0].sha256 -cne $configSha) {
        throw 'STANDARD_ENTRY_INVALID|binding.configSha256 must match the authority input manifest.'
    }

    [void]$resultArtifact
    return $true
}

function New-StandardEntryPointBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $CandidateRoot,
        [Parameter(Mandatory = $true)] [string] $AuthorityRoot,
        [Parameter(Mandatory = $true)] [string] $CandidateRevision,
        [Parameter(Mandatory = $true)] [string] $AuthorityRevision,
        [Parameter(Mandatory = $true)] [string] $EntryId,
        [Parameter(Mandatory = $true)] [string] $EventName,
        [Parameter(Mandatory = $true)] [string[]] $RequiredChecks,
        [Parameter(Mandatory = $true)] [string] $ResultArtifact,
        [switch] $AllowDevelopmentContent
    )

    $CandidateRevision = Assert-SEPString -Value $CandidateRevision -Context 'candidateRevision' -Pattern '^[0-9a-f]{40}$'
    $AuthorityRevision = Assert-SEPString -Value $AuthorityRevision -Context 'authorityRevision' -Pattern '^[0-9a-f]{40}$'
    $EntryId = Assert-SEPString -Value $EntryId -Context 'entryId' -Pattern '^[a-z0-9]+(?:[.-][a-z0-9]+)*$'
    if ($EventName -cnotin @('pull_request', 'push', 'workflow_dispatch', 'local-contract')) {
        throw 'STANDARD_ENTRY_INVALID|eventName is unsupported.'
    }
    $ResultArtifact = Assert-SEPSafeRelativePath -Value $ResultArtifact -Context 'resultArtifact' -JsonFile
    if ($RequiredChecks.Count -eq 0) { throw 'STANDARD_ENTRY_INVALID|requiredChecks must not be empty.' }
    $checkSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $checks = @()
    foreach ($check in $RequiredChecks) {
        $check = Assert-SEPString -Value $check -Context 'requiredChecks item'
        if (-not $checkSet.Add($check)) { throw 'STANDARD_ENTRY_INVALID|requiredChecks contains a duplicate.' }
        $checks += $check
    }
    $checks = [string[]]$checks
    [Array]::Sort($checks, [StringComparer]::Ordinal)

    $candidateFullRoot = [IO.Path]::GetFullPath($CandidateRoot)
    $authorityFullRoot = [IO.Path]::GetFullPath($AuthorityRoot)
    [void](Assert-SEPPathHasNoReparsePoints -Path $candidateFullRoot -Context 'candidate root')
    [void](Assert-SEPPathHasNoReparsePoints -Path $authorityFullRoot -Context 'authority root')
    if (-not (Test-Path -LiteralPath $candidateFullRoot -PathType Container)) { throw 'STANDARD_ENTRY_BLOCKED|candidate root is missing.' }
    if (-not (Test-Path -LiteralPath $authorityFullRoot -PathType Container)) { throw 'STANDARD_ENTRY_BLOCKED|authority root is missing.' }

    $candidateHeadBefore = Get-SEPHeadRevision -Root $candidateFullRoot -Role 'candidate'
    $authorityHeadBefore = Get-SEPHeadRevision -Root $authorityFullRoot -Role 'authority'
    if ($candidateHeadBefore -cne $CandidateRevision) { throw 'STANDARD_ENTRY_BLOCKED|candidateRevision does not match candidate HEAD.' }
    if ($authorityHeadBefore -cne $AuthorityRevision) { throw 'STANDARD_ENTRY_BLOCKED|authorityRevision does not match authority HEAD.' }

    $candidateFirst = Get-SEPInputInventory -Root $candidateFullRoot -Role 'candidate'
    $authorityFirst = Get-SEPInputInventory -Root $authorityFullRoot -Role 'authority'
    $candidateDirty = Test-SEPInputTreeDirty -Root $candidateFullRoot -Inventory $candidateFirst
    $authorityDirty = Test-SEPInputTreeDirty -Root $authorityFullRoot -Inventory $authorityFirst
    if (-not $AllowDevelopmentContent -and ($candidateDirty -or $authorityDirty)) {
        throw 'STANDARD_ENTRY_BLOCKED|immutable content mode rejects modified or untracked input files; pass -AllowDevelopmentContent to bind actual development bytes.'
    }

    $candidateSecond = Get-SEPInputInventory -Root $candidateFullRoot -Role 'candidate'
    $authoritySecond = Get-SEPInputInventory -Root $authorityFullRoot -Role 'authority'
    if (-not (Test-SEPInventoryEqual -First $candidateFirst -Second $candidateSecond) -or
        -not (Test-SEPInventoryEqual -First $authorityFirst -Second $authoritySecond)) {
        throw 'STANDARD_ENTRY_BLOCKED|input file inventory or hashes changed during binding scan.'
    }
    $candidateHeadAfter = Get-SEPHeadRevision -Root $candidateFullRoot -Role 'candidate'
    $authorityHeadAfter = Get-SEPHeadRevision -Root $authorityFullRoot -Role 'authority'
    if ($candidateHeadBefore -cne $candidateHeadAfter -or $authorityHeadBefore -cne $authorityHeadAfter) {
        throw 'STANDARD_ENTRY_BLOCKED|candidate or authority HEAD changed during binding scan.'
    }

    $manifestEntries = @($candidateSecond.entries) + @($authoritySecond.entries)
    $manifest = Sort-SEPManifestEntries -Entries $manifestEntries
    $authorityGate = @($manifest | Where-Object { $_.role -ceq 'authority' -and $_.path -ceq 'docs/standards/validation-security-gate.json' })
    if ($authorityGate.Count -ne 1) { throw 'STANDARD_ENTRY_BLOCKED|authority validation-security-gate.json input is missing.' }

    $binding = [pscustomobject][ordered]@{
        schemaVersion = 1
        entryId = $EntryId
        eventName = $EventName
        candidateRevision = $CandidateRevision
        authorityRevision = $AuthorityRevision
        runtime = Get-StandardEntryPointRuntime
        configSha256 = [string]$authorityGate[0].sha256
        requiredChecks = [string[]]$checks
        resultArtifact = $ResultArtifact
        contentMode = if ($AllowDevelopmentContent) { 'development' } else { 'immutable' }
        inputFileManifest = [object[]]$manifest
    }
    [void](Assert-SEPBindingObject -Binding $binding)
    return $binding
}

function Assert-StandardEntryPointBinding {
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Object')] [object] $Binding,
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')] [string] $BindingPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $document = Read-SEPJsonFile -Path $BindingPath -Context 'binding'
        $Binding = $document.value
    }
    return [bool](Assert-SEPBindingObject -Binding $Binding)
}

function Test-SEPStringArrayEqual {
    param([object[]] $First, [object[]] $Second)
    if ($First.Count -ne $Second.Count) { return $false }
    for ($index = 0; $index -lt $First.Count; $index++) {
        if ([string]$First[$index] -cne [string]$Second[$index]) { return $false }
    }
    return $true
}

function Test-SEPBindingEqual {
    param([Parameter(Mandatory = $true)] $Expected, [Parameter(Mandatory = $true)] $Actual)

    foreach ($name in @('entryId', 'eventName', 'candidateRevision', 'authorityRevision', 'configSha256', 'resultArtifact', 'contentMode')) {
        if ([string](Get-SEPExactProperty -Object $Expected -Name $name) -cne [string](Get-SEPExactProperty -Object $Actual -Name $name)) { return $false }
    }
    $expectedRuntime = Get-SEPExactProperty -Object $Expected -Name 'runtime'
    $actualRuntime = Get-SEPExactProperty -Object $Actual -Name 'runtime'
    foreach ($name in @('os', 'psEdition', 'psVersion')) {
        if ([string](Get-SEPExactProperty -Object $expectedRuntime -Name $name) -cne [string](Get-SEPExactProperty -Object $actualRuntime -Name $name)) { return $false }
    }
    if (-not (Test-SEPStringArrayEqual -First @((Get-SEPExactProperty -Object $Expected -Name 'requiredChecks')) -Second @((Get-SEPExactProperty -Object $Actual -Name 'requiredChecks')))) { return $false }

    $expectedManifest = @((Get-SEPExactProperty -Object $Expected -Name 'inputFileManifest'))
    $actualManifest = @((Get-SEPExactProperty -Object $Actual -Name 'inputFileManifest'))
    if ($expectedManifest.Count -ne $actualManifest.Count) { return $false }
    for ($index = 0; $index -lt $expectedManifest.Count; $index++) {
        foreach ($name in @('role', 'path', 'sha256')) {
            if ([string](Get-SEPExactProperty -Object $expectedManifest[$index] -Name $name) -cne [string](Get-SEPExactProperty -Object $actualManifest[$index] -Name $name)) { return $false }
        }
    }
    return $true
}

function Assert-SEPResultObject {
    param([Parameter(Mandatory = $true)] $ExpectedBinding, [Parameter(Mandatory = $true)] $Result)

    [void](Assert-SEPBindingObject -Binding $ExpectedBinding)
    Assert-SEPExactProperties -Object $Result -Expected $script:StandardEntryPointResultProperties -Context 'result'
    if ((Assert-SEPInteger -Value (Get-SEPExactProperty -Object $Result -Name 'schemaVersion') -Context 'result.schemaVersion') -ne 1) {
        throw 'STANDARD_ENTRY_INVALID|result.schemaVersion must be 1.'
    }
    if ((Get-SEPExactProperty -Object $Result -Name 'status') -cne 'passed') { throw 'STANDARD_ENTRY_BLOCKED|result.status must be passed.' }
    if ((Get-SEPExactProperty -Object $Result -Name 'executed') -isnot [bool] -or -not (Get-SEPExactProperty -Object $Result -Name 'executed')) {
        throw 'STANDARD_ENTRY_BLOCKED|result.executed must be typed true.'
    }
    if ((Get-SEPExactProperty -Object $Result -Name 'releaseEligible') -isnot [bool] -or (Get-SEPExactProperty -Object $Result -Name 'releaseEligible')) {
        throw 'STANDARD_ENTRY_BLOCKED|result.releaseEligible must be typed false.'
    }

    $actualBinding = Get-SEPExactProperty -Object $Result -Name 'binding'
    [void](Assert-SEPBindingObject -Binding $actualBinding)
    if (-not (Test-SEPBindingEqual -Expected $ExpectedBinding -Actual $actualBinding)) {
        throw 'STANDARD_ENTRY_BLOCKED|result binding does not match the expected entry identity.'
    }

    $checks = Get-SEPExactProperty -Object $Result -Name 'checks'
    $required = @((Get-SEPExactProperty -Object $ExpectedBinding -Name 'requiredChecks'))
    if ($checks -isnot [array] -or @($checks).Count -ne $required.Count) {
        throw 'STANDARD_ENTRY_BLOCKED|result checks must match requiredChecks exactly.'
    }
    $requiredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $required) { [void]$requiredSet.Add([string]$name) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($check in @($checks)) {
        Assert-SEPExactProperties -Object $check -Expected $script:StandardEntryPointCheckProperties -Context 'result.checks item'
        $name = Assert-SEPString -Value (Get-SEPExactProperty -Object $check -Name 'name') -Context 'result.checks.name'
        if (-not $requiredSet.Contains($name) -or -not $seen.Add($name)) {
            throw 'STANDARD_ENTRY_BLOCKED|result checks contain an extra, unknown, or duplicate check.'
        }
        if ((Get-SEPExactProperty -Object $check -Name 'status') -cne 'passed') {
            throw "STANDARD_ENTRY_BLOCKED|required check '$name' did not pass."
        }
        if ((Get-SEPExactProperty -Object $check -Name 'executed') -isnot [bool] -or -not (Get-SEPExactProperty -Object $check -Name 'executed')) {
            throw "STANDARD_ENTRY_BLOCKED|required check '$name' was not executed."
        }
        if ((Assert-SEPInteger -Value (Get-SEPExactProperty -Object $check -Name 'exitCode') -Context "check '$name' exitCode") -ne 0) {
            throw "STANDARD_ENTRY_BLOCKED|required check '$name' has a nonzero exit code."
        }
    }
    if ($seen.Count -ne $requiredSet.Count) { throw 'STANDARD_ENTRY_BLOCKED|result omits one or more required checks.' }
    return $true
}

function Assert-StandardEntryPointResult {
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Object')] [Parameter(Mandatory = $true, ParameterSetName = 'ObjectPath')] [object] $ExpectedBinding,
        [Parameter(Mandatory = $true, ParameterSetName = 'Object')] [object] $Result,
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')] [string] $ExpectedBindingPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')] [Parameter(Mandatory = $true, ParameterSetName = 'ObjectPath')] [string] $ResultPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $expectedDocument = Read-SEPJsonFile -Path $ExpectedBindingPath -Context 'expected binding'
        $resultDocument = Read-SEPJsonFile -Path $ResultPath -Context 'result'
        $ExpectedBinding = $expectedDocument.value
        $Result = $resultDocument.value
    } elseif ($PSCmdlet.ParameterSetName -eq 'ObjectPath') {
        $resultDocument = Read-SEPJsonFile -Path $ResultPath -Context 'result'
        $Result = $resultDocument.value
    }
    $verified = [bool](Assert-SEPResultObject -ExpectedBinding $ExpectedBinding -Result $Result)
    if ($verified) { $script:StandardEntryLastVerifiedBinding = $ExpectedBinding }
    return $verified
}

Export-ModuleMember -Function Get-StandardEntryPointRuntime, New-StandardEntryPointBinding, Assert-StandardEntryPointBinding, Assert-StandardEntryPointResult

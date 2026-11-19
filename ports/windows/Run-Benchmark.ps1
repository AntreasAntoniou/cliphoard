param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$PolicyExecutable,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateRange(1, 20)][int]$Repeat = 1,
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 180,
    [switch]$IncludeModels,
    [switch]$IncludeSearchEvaluation,
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).ProviderPath
$PolicyExecutable = (Resolve-Path -LiteralPath $PolicyExecutable).ProviderPath
# A unique run directory preserves earlier receipts and prevents concurrent runs
# from overwriting each other's evidence.
$runDirectory = Join-Path $OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runDirectory
$suites = @(
    'hashing', 'detector-parity', 'parity-policy', 'theme', 'storage-parity',
    'embedding-cache', 'tag-parity', 'archive', 'streaming-archive',
    'manager-import', 'document', 'perceptual', 'agent-protocol',
    'agent-directory', 'agent-controller', 'agent-writer', 'companion',
    'speech-boundary', 'capture-suspension', 'workflow', 'input-policy', 'brand', 'copy-sound'
)
if ($IncludeModels) {
    $suites += @('ogma', 'openvision', 'gemma', 'model-switch', 'speech', 'media-index', 'media-decode')
}
if ($IncludeSearchEvaluation) {
    $suites += @('search-evaluation-text', 'search-evaluation-images')
}
if ($Only.Count -gt 0) {
    if (@($Only | Where-Object { $_ -notin $suites }).Count -gt 0) { throw 'Unknown or disabled benchmark suite.' }
    $suites = @($suites | Where-Object { $_ -in $Only })
}
$results = [Collections.Generic.List[object]]::new()
$started = [DateTime]::UtcNow.ToString('o')
$executableHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
$assemblyHash = (Get-FileHash -LiteralPath ([IO.Path]::ChangeExtension($Executable, '.dll')) -Algorithm SHA256).Hash
$policyAssemblyHash = (Get-FileHash -LiteralPath ([IO.Path]::ChangeExtension($PolicyExecutable, '.dll')) -Algorithm SHA256).Hash
$image = [IO.File]::ReadAllBytes($Executable)
$machine = [BitConverter]::ToUInt16($image, [BitConverter]::ToInt32($image, 60) + 4)
for ($iteration = 1; $iteration -le $Repeat; $iteration++) {
    foreach ($suite in $suites) {
        $prefix = Join-Path $runDirectory ("$iteration-$suite")
        $process = [Diagnostics.Process]::new()
        $process.StartInfo.FileName = $Executable
        $process.StartInfo.Arguments = "--$suite-checks"
        $quality = $suite.StartsWith('search-evaluation-')
        if ($quality) { $process.StartInfo.Arguments = "--$suite" }
        if ($suite -eq 'input-policy') {
            $process.StartInfo.FileName = $PolicyExecutable
            $process.StartInfo.Arguments = ''
        }
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $status = 'failed'
        $exitCode = $null
        $checks = 0
        $failure = $null
        try {
            if (-not $process.Start()) { throw 'Fixture process did not start.' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $status = 'timeout'
                $process.Kill()
                $process.WaitForExit()
            }
            $exitCode = $process.ExitCode
            $output = $stdout.GetAwaiter().GetResult()
            [IO.File]::WriteAllText($prefix + '.out.log', $output)
            [IO.File]::WriteAllText($prefix + '.err.log', $stderr.GetAwaiter().GetResult())
            $receipts = @($output -split '\r?\n' | Where-Object { $_.TrimStart().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
            $passed = @($receipts | Where-Object { $_.status -eq 'passed' })
            if ($quality -and $status -ne 'timeout' -and $exitCode -eq 0 -and $receipts.Count -gt 0) {
                $misses = 0
                foreach ($receipt in $receipts) {
                    if ($receipt.evaluation -ne 'synthetic-search-v1' -or @($receipt.outcomes).Count -eq 0) {
                        throw 'Missing search evaluation outcomes.'
                    }
                    foreach ($outcome in $receipt.outcomes) {
                        $checks++
                        if (@($outcome.Relevant).Count -eq 0) {
                            if (@($outcome.Returned).Count -gt 0) { $misses++ }
                        } elseif ($null -eq $outcome.FirstRelevantRank -or $outcome.FirstRelevantRank -gt 3) {
                            $misses++
                        }
                    }
                }
                $status = 'passed'
                if ($misses -gt 0) { $status = 'failed'; $failure = "$misses retrieval cases missed the top-three or empty-result expectation." }
            }
            if ($status -ne 'timeout' -and $exitCode -eq 0 -and $passed.Count -gt 0) {
                foreach ($receipt in $passed) {
                    foreach ($property in $receipt.PSObject.Properties) {
                        if ($property.Name -notlike '*_checks' -and -not ($suite -eq 'speech' -and $property.Name -eq 'speech_models')) { continue }
                        if ($suite -eq 'input-policy' -and $property.Name -notin @('total_policy_checks', 'deferred_paste_checks')) { continue }
                        $checks += [int]$property.Value
                    }
                }
                if ($checks -gt 0) { $status = 'passed' }
            }
        } catch { $failure = $_.Exception.Message }
        finally { $timer.Stop(); $process.Dispose() }
        $result = [pscustomobject]@{
            suite = $suite; iteration = $iteration; status = $status
            checks = $checks; exit_code = $exitCode
            milliseconds = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            failure = $failure
        }
        $results.Add($result)
        $result | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $runDirectory 'results.jsonl')
        Write-Output ("{0} {1} checks={2} ms={3}" -f $suite, $status, $checks, $result.milliseconds)
    }
}
$failed = @($results | Where-Object { $_.status -ne 'passed' }).Count
$summary = [pscustomobject]@{
    version = 1; started_utc = $started; finished_utc = [DateTime]::UtcNow.ToString('o')
    executable_sha256 = $executableHash; architecture = $env:PROCESSOR_ARCHITECTURE
    assembly_sha256 = $assemblyHash; executable_machine = ('0x{0:X4}' -f $machine)
    policy_executable_sha256 = (Get-FileHash -LiteralPath $PolicyExecutable -Algorithm SHA256).Hash
    policy_assembly_sha256 = $policyAssemblyHash
    cases = $results.Count; failed = $failed
    checks = ($results | Measure-Object checks -Sum).Sum
    includes_models = [bool]$IncludeModels
    includes_search_evaluation = [bool]$IncludeSearchEvaluation
    results = $results.ToArray()
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'summary.json')
Write-Output ("BENCHMARK directory={0} cases={1} checks={2} failed={3}" -f $runDirectory, $results.Count, $summary.checks, $failed)
if ($failed -gt 0) { exit 1 }

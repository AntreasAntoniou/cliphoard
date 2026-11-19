"""Source and reviewed UI-asset bridge to the existing isolated Astrapé Windows development VM."""
import argparse
import base64
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--sync', action='store_true')
p.add_argument('command')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]

# Start-Process -Wait also waits for persistent compiler descendants. A retained
# Process handle captures the actual command's exit without waiting for build servers.
native_runner = r'''
function Invoke-CliphoardNative {
    param([string]$Executable, [string[]]$ArgumentList, [string]$LogPrefix)
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.WorkingDirectory = (Get-Location).ProviderPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $quoted = foreach($argument in $ArgumentList) {
        if($argument.Length -gt 0 -and $argument -notmatch '[\s"]') { $argument }
        else { '"' + [regex]::Replace($argument, '(\\*)("|$)', {
            param($match)
            $slashes = $match.Groups[1].Value
            if($match.Groups[2].Value -eq '"') { $slashes + $slashes + '\"' }
            else { $slashes + $slashes }
        }) + '"' }
    }
    $process.StartInfo.Arguments = $quoted -join ' '
    try {
        if(-not $process.Start()) { throw 'Native command could not start' }
        $null = $process.Handle
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        $resultCode = $process.ExitCode
    } finally { $process.Dispose() }
    if($LogPrefix) {
        [IO.File]::WriteAllText($LogPrefix + '.out.log', $output)
        [IO.File]::WriteAllText($LogPrefix + '.err.log', $errorOutput)
    }
    Write-Output (($output -split '\r?\n' | Select-Object -Last 12) -join "`n")
    if($resultCode -ne 0) { Write-Output $errorOutput; exit 1 }
}
'''

def run(script, source_only=False):
    for attempt in range(3 if source_only else 1):
        result = subprocess.run(['/usr/local/bin/prlctl', 'exec', 'ad50825b-955a-4cd4-a04b-b7fadc860197', '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '-'], input='& {\n$ErrorActionPreference="Stop"\n[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n$OutputEncoding=[Console]::OutputEncoding\n' + script + '\n}\n\n', text=True, encoding="utf-8", errors="replace", capture_output=True)
        if result.returncode == 0 or not source_only:
            break
        time.sleep(attempt + 1)
    print(result.stdout, end='', flush=True)
    print(result.stderr, end='', flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)

if a.sync:
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', 'ports/windows'], cwd=root, text=True).splitlines()
    batch = []
    batch_size = 0
    for rel in paths:
        path = root / rel
        if not path.is_file() or path.suffix not in {'.cs', '.csproj', '.xaml', '.json', '.manifest', '.png', '.ps1', '.xml', '.txt', '.ico', '.wav'}:
            continue
        destination = 'C:\\CliphoardDev\\src\\' + rel.replace('/', '\\')
        data = base64.b64encode(path.read_bytes()).decode()
        script = f"[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName('{destination}')) | Out-Null\n[IO.File]::WriteAllBytes('{destination}',[Convert]::FromBase64String('{data}'))\nWrite-Output 'SYNC {rel}'"
        if batch_size + len(script) > 900_000 and batch:
            run('\n'.join(batch), source_only=True)
            batch, batch_size = [], 0
        batch.append(script)
        batch_size += len(script)
    if batch:
        run('\n'.join(batch), source_only=True)
run('$env:DOTNET_CLI_TELEMETRY_OPTOUT="1"\nSet-Location C:\\CliphoardDev\\src\n' + native_runner + '\n' + a.command)

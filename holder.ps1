# Reports who holds a TCP port, as the OS sees it.
#
# Used by main.luau, which cannot ask Tern for this: ProcessInfo carries no
# ports and ProcessQuery has no port filter, so the only source is the OS.
#
# Writes KEY=VALUE lines and exits non-zero when nothing holds the port:
#   3  nothing is listening
#   4  the connection went away between the two lookups
# The port comes from argv[0], so this file holds no fixed port of its own.

$port = $args[0]
if (-not $port) { exit 2 }

$conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $conn) { exit 3 }

$proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" `
    -ErrorAction SilentlyContinue
if (-not $proc) { exit 4 }

$parent = "gone"
if ($proc.ParentProcessId) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" `
        -ErrorAction SilentlyContinue
    if ($p) { $parent = $p.Name }
}

Write-Output ("PID=" + $proc.ProcessId)
Write-Output ("NAME=" + $proc.Name)
Write-Output ("CMD=" + ($proc.CommandLine -replace "[\r\n]", " "))
Write-Output ("PARENT=" + $parent)

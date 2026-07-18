$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$destination = Join-Path $PSScriptRoot 'FPC-3.2.2-Installers'
New-Item -ItemType Directory -Force -Path $destination | Out-Null

$packages = @(
    @{
        Name = 'fpc-3.2.2.i386-win32.exe'
        Uri  = 'https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.exe'
    },
    @{
        Name = 'fpc-3.2.2.i386-win32.cross.i8086-msdos.exe'
        Uri  = 'https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.cross.i8086-msdos.exe'
    }
)

foreach ($package in $packages) {
    $output = Join-Path $destination $package.Name
    $temporary = "$output.part"
    Remove-Item -Force -ErrorAction SilentlyContinue $temporary

    Write-Host "Downloading $($package.Name)..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $package.Uri -OutFile $temporary
        $item = Get-Item $temporary
        if ($item.Length -lt 1MB) {
            throw "The download is unexpectedly small ($($item.Length) bytes)."
        }

        $stream = [IO.File]::OpenRead($temporary)
        try {
            if (($stream.ReadByte() -ne 0x4D) -or ($stream.ReadByte() -ne 0x5A)) {
                throw 'The downloaded file is not a Windows executable (missing MZ header).'
            }
        }
        finally {
            $stream.Dispose()
        }

        Move-Item -Force $temporary $output
    }
    catch {
        Remove-Item -Force -ErrorAction SilentlyContinue $temporary
        throw
    }
}

Write-Host ''
Write-Host 'Downloads completed. Install the native Win32 package first, then the i8086-MS-DOS add-on.'

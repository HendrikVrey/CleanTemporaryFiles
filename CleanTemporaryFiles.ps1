using namespace System.Security.Principal

[CmdletBinding(SupportsShouldProcess = $true)]
param()

if (-not ([WindowsPrincipal][WindowsIdentity]::GetCurrent()).IsInRole([WindowsBuiltInRole]::Administrator)) {
    $Process = Start-Process -PassThru -FilePath "pwsh.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    $Process.WaitForExit() 
    exit
}

class CleanerEngine {
    [DateTime]$ScriptStartTime
    [string]$LogFile
    [double]$TotalSpaceFreed = 0
    [bool]$IsAdmin = $false

    CleanerEngine() {
        $this.ScriptStartTime = [DateTime]::Now
        $this.LogFile = "$env:TEMP\CleanTempFiles_$($this.ScriptStartTime.ToString('yyyyMMdd_HHmmss')).log"
    }

    [void] WriteLog([string]$message) {
        $timestamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        $logEntry = "$timestamp - $message"
        $logEntry | Out-File $this.LogFile -Append
        
        switch -Wildcard ($message) {
            "*ERROR*"   { Write-Host $logEntry -ForegroundColor Red }
            "*SKIPPED*" { Write-Host $logEntry -ForegroundColor Yellow }
            "*CLEANED*" { Write-Host $logEntry -ForegroundColor Green }
            default     { Write-Host $logEntry }
        }
    }

    [bool] ConfirmAction([string]$title, [string]$message) {
        Write-Host "`n=== $title ===" -ForegroundColor Cyan
        do {
            $response = Read-Host "Clear $message [Yes(y) / No(n) / Quit(q)]"
            switch ($response.ToUpper()) {
                'Y' { return $true }
                'N' { return $false }
                'Q' { 
                    $this.WriteLog("[ABORTED] Operation canceled by user")
                    exit 
                }
                default {
                    Write-Host "Invalid input. Please choose Y (Yes), N (No), or Q (Quit)" -ForegroundColor Yellow
                }
            }
        } while ($true)
        return $false
    }

    [void] ClearTempDirectory([string]$path, [string]$name) {
        if (-not (Test-Path $path)) {
            $this.WriteLog("[SKIPPED] $name - Path not found")
            return
        }

        $isWindowsUpdatePath = $path -like "*SoftwareDistribution\Download*"
        $serviceName = "wuauserv"

        if ($isWindowsUpdatePath) {
            try {
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                if ($service.Status -eq "Running") {
                    $this.WriteLog("[INFO] Stopping Windows Update service...")
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    [System.Threading.Thread]::Sleep(2000) 
                    $this.WriteLog("[INFO] Windows Update service stopped")
                }
            }
            catch {
                $this.WriteLog("[ERROR] Failed to stop Windows Update service: $_")
                return
            }
        }

        try {
            $initialItems = Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | 
                Sort-Object @{Expression={$_.FullName.Length}; Descending=$true} -ErrorAction SilentlyContinue

            if (-not $initialItems) {
                $this.WriteLog("[CLEANED] $name - 0 files deleted, Freed 0 MB")
                return
            }

            $deletedSize = 0
            $deletedCount = 0

            $initialItems | ForEach-Object {
                try {
                    if ($PSCmdlet.ShouldProcess($_.FullName, "Delete")) {
                        $itemSize = if (-not $_.PSIsContainer) { $_.Length } else { 0 }
                        Remove-Item $_.FullName -Force -Recurse -ErrorAction Stop
                        $deletedCount++
                        $deletedSize += $itemSize
                    }
                }
                catch {
                    #Intentionally empty to skip files in use
                }
            }

            $this.TotalSpaceFreed += $deletedSize
            $spaceMessage = "Freed $([math]::Round($deletedSize / 1MB, 2)) MB"
            $this.WriteLog("[CLEANED] $name - $deletedCount/$($initialItems.Count) files deleted, $spaceMessage")
        }
        finally {
            if ($isWindowsUpdatePath) {
                try {
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
                    if ($service.Status -ne "Running") {
                        $this.WriteLog("[INFO] Restarting Windows Update service...")
                        Start-Service -Name $serviceName -ErrorAction Stop
                        [System.Threading.Thread]::Sleep(2000) 
                        $this.WriteLog("[INFO] Windows Update service started")
                    }
                }
                catch {
                    $this.WriteLog("[ERROR] Failed to restart Windows Update service: $_")
                }
            }
        }
    }

    [void] ClearRecycleBin([string]$name) {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(0xA)
        $items = $recycleBin.Items()
        $initialCount = $items.Count

        if ($initialCount -eq 0) {
            $this.WriteLog("[CLEANED] $name - 0 files deleted, Freed 0 MB")
            return
        }

        $initialSize = 0
        foreach ($item in $items) {
            $initialSize += $item.Size
        }

        $deletedCount = 0
        if ($PSCmdlet.ShouldProcess($name, "Empty Recycle Bin")) {
            Clear-RecycleBin -Force -ErrorAction Stop
            $deletedCount = $initialCount
        }

        $spaceFreed = $initialSize
        $this.TotalSpaceFreed += $spaceFreed

        $spaceMessage = "Freed $([math]::Round($spaceFreed / 1MB, 2)) MB"
        $this.WriteLog("[CLEANED] $name - $deletedCount/$initialCount files deleted, $spaceMessage")
    }

    [void] Execute() {
        Write-Host "`n=== SYSTEM CLEANUP TOOL ===" -ForegroundColor Cyan
        Write-Host "This script will deletes useless files" -ForegroundColor Yellow
        Write-Host "These files are not needed and Windows never deletes them using up storage space" -ForegroundColor Yellow
        Write-Host "There are also options to delete files in your Downloads folder and Recycle Bin" -ForegroundColor Yellow
        Write-Host "Targets: Temp files, Downloads folder, Recycle Bin and Windows Update downloaded files" -ForegroundColor Yellow
        Write-Host "Files not deleted are in use by the Operating System`n" -ForegroundColor Yellow
        Write-Host "Close all applications before continuing for the best results`n"

        $this.ProcessTasks()
        $this.GenerateReport()
    }

    hidden [void] ProcessTasks() {
        $tasks = [System.Collections.Generic.List[hashtable]]::new()
        $tasks.Add(@{
            Name = "User Temporary Files"
            Path = $env:TEMP
        })
    
        $tasks.Add(@{
            Name = "System Temporary Files"
            Path = "$env:SystemRoot\Temp"
        })
    
        $tasks.Add(@{
            Name = "Downloads Folder"
            Path = [Environment]::GetFolderPath('User') + "\Downloads"
        })
    
        $tasks.Add(@{
            Name = "Windows Update Downloads"
            Path = "$env:SystemRoot\SoftwareDistribution\Download"
        })
    
        $tasks.Add(@{
            Name = "Recycle Bin"
        })
    
        foreach ($task in $tasks) {
            if (-not $this.ConfirmAction($task.Name, $task.Name)) {
                $this.WriteLog("[SKIPPED] User cancelled: Deleting $($task.Name)")
                continue
            }
            
            if ($task.Name -eq "Recycle Bin") {
                $this.ClearRecycleBin($task.Name)
            }
            else {
                $this.ClearTempDirectory($task.Path, $task.Name)
            }
        }
    }

    hidden [void] GenerateReport() {
        $executionTime = [DateTime]::Now - $this.ScriptStartTime
        Write-Host "`n=== CLEANING COMPLETE ===" -ForegroundColor Cyan
        Write-Host "Total space recovered: $([math]::Round($this.TotalSpaceFreed / 1MB, 2)) MB" -ForegroundColor Green
        Write-Host "Operation duration: $($executionTime.ToString('hh\:mm\:ss'))"
        Write-Host "Detailed log: $($this.LogFile)`n" -ForegroundColor Yellow
    }
}

$cleaner = [CleanerEngine]::new()
$cleaner.Execute()

Write-Host "Press any key to exit..." -ForegroundColor Cyan
$null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
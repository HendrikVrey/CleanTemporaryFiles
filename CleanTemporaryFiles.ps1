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
        $this.IsAdmin = [WindowsPrincipal]::new([WindowsIdentity]::GetCurrent()).IsInRole([WindowsBuiltInRole]::Administrator)
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
        
        $initialItems = Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | 
            Sort-Object @{Expression={$_.FullName.Length}; Descending=$true} -ErrorAction SilentlyContinue
        
        if (-not $initialItems) {
            $this.WriteLog("[CLEANED] $name - 0 items deleted, Freed 0 MB")
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
                #Intentionally to skip errors for locked files currently in use
            }
        }

        $this.TotalSpaceFreed += $deletedSize
        $spaceMessage = "Freed $([math]::Round($deletedSize / 1MB, 2)) MB"
        $this.WriteLog("[CLEANED] $name - $deletedCount/$($initialItems.Count) items deleted, $spaceMessage")
    }

    [void] ClearRecycleBin([string]$name) {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(0xA)
        $items = $recycleBin.Items()
        $initialCount = $items.Count

        if ($initialCount -eq 0) {
            $this.WriteLog("[CLEANED] $name - 0/0 files deleted, Freed 0 MB")
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
        Write-Host "This script will clean up temporary files and folders" -ForegroundColor Yellow
        Write-Host "Targets: Temp files, Downloads folder, and Recycle Bin" -ForegroundColor Yellow
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
            Name = "Recycle Bin"
        })

        foreach ($task in $tasks) {
            if ($task.Admin -and -not $this.IsAdmin) {
                $this.WriteLog("[SKIPPED] $($task.Name) - Requires administrator rights")
                continue
            }

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
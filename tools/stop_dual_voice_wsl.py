"""Stop only the configured project voice processes, including accepted Ciel."""
import base64
import json
import os
from pathlib import Path
import signal
import sys
import time


def managed_voice(argv, cwd, settings):
    if not argv or os.path.normpath(argv[0]) != os.path.normpath(settings['python']):
        return None
    if os.path.normpath(cwd) != os.path.normpath(settings['root']):
        return None
    if not any(Path(arg).name == 'api_v2.py' for arg in argv[1:]):
        return None
    try:
        port = int(argv[argv.index('-p') + 1])
        config = argv[argv.index('-c') + 1]
    except (ValueError, IndexError):
        return None
    if config != settings['configs'].get(str(port)):
        return None
    return port


def process_identity(entry):
    # starttime follows the process name, which may itself contain spaces.
    return (entry / 'stat').read_text().rsplit(')', 1)[1].split()[19]


def stop_voices(settings):
    stopped = 0
    failed = 0
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / 'cmdline').read_bytes().decode().rstrip('\0').split('\0')
            port = managed_voice(argv, str((entry / 'cwd').resolve()), settings)
            if port is None:
                continue
            pid = int(entry.name)
            identity = process_identity(entry)
            print(f"{'[dry-run] Would stop' if settings['dry_run'] else 'Stopping'} WSL voice port {port}, PID {pid}", flush=True)
            stopped += 1
            if settings['dry_run']:
                continue
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 3
            while entry.exists() and time.monotonic() < deadline:
                if process_identity(entry) != identity:
                    break
                time.sleep(0.1)
            if entry.exists() and process_identity(entry) == identity:
                os.kill(pid, signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (PermissionError, OSError, ValueError) as error:
            failed += 1
            print(f"Could not stop managed WSL voice PID {entry.name}: {type(error).__name__}", file=sys.stderr)
    if not stopped:
        print('No managed WSL voice processes found.')
    return 1 if failed else 0


if __name__ == '__main__':
    settings = json.loads(base64.b64decode(sys.argv[1]))
    raise SystemExit(stop_voices(settings))

import asyncio
import json
import os

import psutil
from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import uvicorn
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="ProxyMon", docs_url=None, redoc_url=None)

security = HTTPBearer(auto_error=False)

NSENTER_PREFIX = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--"]
XRAY_CONFIG_PATH = "/usr/local/etc/xray/config.json"
PROXYMON_DIR = "/opt/proxymon"


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    token = os.getenv("TOKEN", "")
    if not token:
        return
    if credentials is None or credentials.credentials != token:
        raise HTTPException(status_code=401, detail="Unauthorized")


async def run_host_command(*args, timeout: int = 10):
    proc = await asyncio.create_subprocess_exec(
        *NSENTER_PREFIX, *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    return stdout.decode(errors="replace"), stderr.decode(errors="replace"), proc.returncode


# ── Health (no auth) ──────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok"}


# ── WARP ──────────────────────────────────────────────────────────

@app.get("/warp/status")
async def warp_status(_=Depends(verify_token)):
    try:
        stdout, stderr, code = await run_host_command(
            "warp-cli", "--accept-tos", "status",
        )
        if "Status update: Connected" in stdout:
            status = "Connected"
        else:
            status = "Disconnected"
        return {"warp_status": status, "raw_stdout": stdout, "exit_code": code}
    except asyncio.TimeoutError:
        return {"warp_status": "Error", "error": "Timeout executing warp-cli"}
    except FileNotFoundError:
        return {"warp_status": "Error", "error": "warp-cli or nsenter not found"}
    except Exception as e:
        return {"warp_status": "Error", "error": str(e)}


@app.post("/warp/reconnect")
async def warp_reconnect(_=Depends(verify_token)):
    try:
        cmd = os.getenv("WARP_RECONNECT_CMD", "warp-cli --accept-tos connect")
        parts = cmd.split()
        stdout, stderr, code = await run_host_command(*parts, timeout=15)
        return {
            "success": code == 0,
            "exit_code": code,
            "stdout": stdout,
            "stderr": stderr,
        }
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── System stats ──────────────────────────────────────────────────

@app.get("/stats")
async def system_stats(_=Depends(verify_token)):
    try:
        cpu_usage = await asyncio.to_thread(psutil.cpu_percent, 0.5)
        mem = psutil.virtual_memory()

        disk_stdout, _, disk_code = await run_host_command("df", "--output=pcent", "/")
        disk_usage = None
        if disk_code == 0:
            lines = disk_stdout.strip().split("\n")
            if len(lines) >= 2:
                disk_usage = float(lines[1].strip().rstrip("%"))

        return {
            "cpu_usage": cpu_usage,
            "ram_usage": round(mem.percent, 1),
            "ram_total_mb": round(mem.total / (1024 * 1024)),
            "ram_used_mb": round(mem.used / (1024 * 1024)),
            "disk_usage": disk_usage,
        }
    except Exception as e:
        return {"error": str(e)}


# ── 4.1  Clear system logs ────────────────────────────────────────

@app.post("/system/clear-logs")
async def clear_system_logs(_=Depends(verify_token)):
    try:
        stdout, stderr, code = await run_host_command(
            "truncate", "-s", "0",
            "/var/log/syslog", "/var/log/syslog.1", "/var/log/btmp",
            timeout=10,
        )
        return {"success": code == 0, "exit_code": code, "stdout": stdout, "stderr": stderr}
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── 4.2  Self-update (survives container restart) ─────────────────

@app.post("/system/update")
async def system_update(_=Depends(verify_token)):
    try:
        update_script = (
            f"nohup sh -c '"
            f"sleep 2 && "
            f"cd {PROXYMON_DIR} && "
            f"docker compose pull && "
            f"docker compose up -d --force-recreate"
            f"' > /tmp/proxymon-update.log 2>&1 &"
        )
        stdout, stderr, code = await run_host_command(
            "bash", "-c", update_script, timeout=10,
        )
        return {
            "success": code == 0,
            "message": "Update scheduled. Container will restart shortly.",
            "log_file": "/tmp/proxymon-update.log",
        }
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout scheduling update"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── 4.3  View xray config ────────────────────────────────────────

@app.get("/xray/config")
async def get_xray_config(_=Depends(verify_token)):
    try:
        stdout, stderr, code = await run_host_command("cat", XRAY_CONFIG_PATH, timeout=5)
        if code != 0:
            return {"success": False, "error": stderr.strip() or f"Exit code {code}"}
        try:
            config = json.loads(stdout)
        except json.JSONDecodeError:
            config = stdout
        return {"success": True, "config": config}
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── 4.4  Edit xray config ────────────────────────────────────────

@app.put("/xray/config")
async def update_xray_config(request: Request, _=Depends(verify_token)):
    try:
        body = await request.json()
        config_json = json.dumps(body, indent=2, ensure_ascii=False)

        tmp_path = "/tmp/xray_config_new.json"
        write_cmd = f"cat > {tmp_path} << 'XRAYEOF'\n{config_json}\nXRAYEOF"
        stdout, stderr, code = await run_host_command("bash", "-c", write_cmd, timeout=10)
        if code != 0:
            return {"success": False, "error": f"Failed to write temp file: {stderr}"}

        mv_cmd = f"cp {tmp_path} {XRAY_CONFIG_PATH} && rm -f {tmp_path}"
        stdout, stderr, code = await run_host_command("bash", "-c", mv_cmd, timeout=5)
        if code != 0:
            return {"success": False, "error": f"Failed to apply config: {stderr}"}

        stdout, stderr, code = await run_host_command(
            "systemctl", "restart", "xray", timeout=15,
        )
        restarted = code == 0
        return {
            "success": True,
            "xray_restarted": restarted,
            "message": "Config updated and xray restarted" if restarted
            else f"Config saved but xray restart failed: {stderr}",
        }
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Request body must be valid JSON")
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── 4.5  Xray status ─────────────────────────────────────────────

@app.get("/xray/status")
async def xray_status(_=Depends(verify_token)):
    try:
        svc_out, svc_err, svc_code = await run_host_command(
            "systemctl", "is-active", "xray", timeout=5,
        )
        ver_out, ver_err, ver_code = await run_host_command(
            "xray", "version", timeout=5,
        )
        return {
            "success": True,
            "service_active": svc_out.strip() == "active",
            "service_status": svc_out.strip(),
            "version_output": ver_out.strip(),
        }
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── 4.6  Change xray version ─────────────────────────────────────

@app.post("/xray/version")
async def change_xray_version(request: Request, _=Depends(verify_token)):
    try:
        body = await request.json()
        version = body.get("version")
        if not version:
            raise HTTPException(
                status_code=400,
                detail="'version' field required (e.g. '1.8.24')",
            )

        install_cmd = (
            "bash -c \"$(curl -fsSL "
            "https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" "
            f"@ install -u root --version {version}"
        )
        stdout, stderr, code = await run_host_command(
            "bash", "-c", install_cmd, timeout=120,
        )

        if code == 0:
            await run_host_command("systemctl", "restart", "xray", timeout=15)

        return {
            "success": code == 0,
            "version": version,
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": code,
        }
    except HTTPException:
        raise
    except asyncio.TimeoutError:
        return {"success": False, "error": "Timeout (install may still be running)"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ── Entrypoint ────────────────────────────────────────────────────

if __name__ == "__main__":
    cert_file = os.getenv("TLS_CERT", "")
    key_file = os.getenv("TLS_KEY", "")
    port = int(os.getenv("API_PORT", "5757"))

    ssl_kwargs = {}
    if cert_file and key_file and os.path.exists(cert_file) and os.path.exists(key_file):
        ssl_kwargs = {"ssl_certfile": cert_file, "ssl_keyfile": key_file}

    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=port,
        log_level="info",
        **ssl_kwargs,
    )

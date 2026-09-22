# Step-by-Step Guide: Starting Tailscale & Tailscale Funnel for RoadEye Compute Node

This guide outlines the exact commands needed on your host machine to start **Tailscale**, expose the local edge inference server (`port 8000`) to the public internet via **Tailscale Funnel**, and launch the backend ingress daemon.

---

### Prerequisites
1. **Admin Console Permissions**: Ensure **Funnel** is turned on in your [Tailscale Admin Console](https://login.tailscale.com/admin/settings/features) under **Access Controls / Feature Flags**.
2. **Terminal**: Open **PowerShell** or **Command Prompt** as Administrator.

---

### Step 1: Start and Authenticate Tailscale

Start the Tailscale background service and connect your workstation to your Tailnet:

```powershell
# 1. Bring Tailscale online and authenticate if needed
tailscale up

# 2. Check connection status and verify your machine's Tailscale IP and node name
tailscale status
```

---

### Step 2: Launch the Local Edge Ingress Server (`port 8000`)

In a **dedicated terminal window**, navigate to the `Tethered` directory, activate the Python virtual environment, and start `funnel_ingress.py`:

```powershell
# 1. Navigate to the Tethered backend directory
cd "c:\The Sketchbook\SEM VII\AutonomousCam\Tethered"

# 2. Activate the virtual environment
.\venv\Scripts\Activate.ps1

# 3. Start the Ingress server (runs on port 8000 by default)
python funnel_ingress.py
```
> You will see Uvicorn start on `http://0.0.0.0:8000` and announce that the AI models (RF-DETR, Depth Anything V2, and 3DGS pipeline) are loaded.

---

### Step 3: Activate Tailscale Funnel (Expose to Public Internet)

Open a **second terminal window** and expose port `8000` to the internet through Tailscale's secure HTTPS reverse proxy:

#### Option A: Run in the Foreground (Recommended for testing/monitoring)
```powershell
tailscale funnel 8000
```

#### Option B: Run in the Background (Persistent daemon mode)
```powershell
tailscale funnel --bg 8000
```

---

### Step 4: Verify Funnel Status & Get Your Public URL

Inspect the active Funnel configuration and copy your public HTTPS URL:

```powershell
# Check current Funnel forwarding status
tailscale funnel status
```

You will receive an output similar to:
```text
https://<your-node-name>.<your-tailnet>.ts.net/ (Funnel on)
|-- / proxy http://127.0.0.1:8000
```

#### Test Endpoint Health
Run a quick health check against your public URL:
```powershell
# Replace with your actual funnel URL
curl.exe https://<your-node-name>.<your-tailnet>.ts.net/health
```
**Expected Response:**
```json
{"status":"online","node_id":"...","gpu":{"device":"NVIDIA GeForce RTX 4060..."},"active_jobs":0}
```

---

### Step 5: Configure the Mobile Application

1. Open the **RoadEye** mobile app on your phone.
2. Go to the **Account** tab $\rightarrow$ tap **Configure**.
3. Set the **Target Compute Node Endpoint** to:
   ```text
   https://<your-node-name>.<your-tailnet>.ts.net
   ```
4. Mobile uploads (Patrol frames and 3DGS video bursts) will now stream directly through this URL without requiring a VPN connection on the phone.

---

### Useful Management Commands

| Action | Command |
| :--- | :--- |
| **Check Tailscale status** | `tailscale status` |
| **View active Funnel routing** | `tailscale funnel status` |
| **Reset / Disable Funnel** | `tailscale funnel reset` |
| **Disconnect Tailscale** | `tailscale down` |
| **View Tailscale CLI version** | `tailscale version` |
```
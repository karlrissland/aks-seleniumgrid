# AKS Selenium Grid Demo

Deploy and run a multi-browser **Selenium Grid 4** cluster on **Azure Kubernetes Service (AKS)** inside a private, VNet-isolated environment accessed via **Azure Bastion** and a **Windows 11 Jumpbox**.

---

## 🏛️ Architecture Overview

```
                          ┌──────────────────────────────────────────────────────────────┐
                          │                        Azure VNet                            │
                          │                                                              │
┌──────────────┐          │  ┌───────────────────────┐      ┌─────────────────────────┐  │
│ Admin / User │─────────>│  │  Azure Bastion        │      │     JumpboxSubnet       │  │
└──────────────┘ (Bastion)│  │  (Developer SKU)      │─────>│  (Windows 11 Jumpbox)   │  │
                          │  └───────────────────────┘ (RDP)│ (az,kubectl,helm,pytest)│  │
                          │                                 └────────────┬────────────┘  │
                          │                                              │               │
                          │                                              │ (Private IP)  │
                          │                                              ▼               │
                          │  ┌────────────────────────────────────────────────────────┐  │
                          │  │                      AksSubnet                         │  │
                          │  │  ┌──────────────────────────────────────────────────┐  │  │
                          │  │  │             AKS 2-Node Cluster                   │  │  │
                          │  │  │  ┌────────────────────────────────────────────┐  │  │  │
                          │  │  │  │ Selenium Grid Hub (Internal LoadBalancer)  │  │  │  │
                          │  │  │  └───────┬───────────────┬────────────────┬───┘  │  │  │
                          │  │  │          │               │                │      │  │  │
                          │  │  │          ▼               ▼                ▼      │  │  │
                          │  │  │   [ Chrome Nodes ] [ Firefox Nodes ] [ Edge Nodes ] │  │
                          │  │  └──────────────────────────────────────────────────┘  │  │
                          │  └────────────────────────────────────────────────────────┘  │
                          └──────────────────────────────────────────────────────────────┘
```

---

## 📂 Repository Structure

```
.
├── .github/
│   └── copilot-instructions.md       # Copilot Agent instructions & project standards
├── azure.yaml                         # Azure Developer CLI (azd) config + provisioning hooks
├── infra/
│   ├── main.bicep                     # azd entry point (subscription scope, creates the RG)
│   ├── main.parameters.json           # azd parameter → environment variable mapping
│   ├── resources.bicep                # Resource-group-scoped orchestrator
│   └── modules/
│       ├── network.bicep              # VNet, Subnets, and NSGs
│       ├── bastion.bicep              # Azure Bastion (Developer SKU, no public IP)
│       ├── privatedns.bicep           # Private DNS zone dev.lab + seleniumgrid A record
│       ├── aks.bicep                  # 2-node AKS cluster with Azure CNI Overlay
│       └── jumpbox.bicep              # Windows 11 desktop + winget bootstrap, repo clone & shortcuts
├── helm/
│   └── selenium-grid/
│       ├── values.yaml                # Custom Helm values for Hub & browser nodes
│       └── README.md                  # Helm deployment instructions
├── tests/
│   ├── conftest.py                    # Pytest fixtures & Selenium Remote WebDriver setup
│   ├── pytest.ini                     # Pytest configuration
│   ├── requirements.txt               # Python test dependencies
│   ├── test_bing.py                   # Bing search UI test suite
│   └── test_google.py                 # Google search UI test suite
├── scripts/
│   ├── install-selenium-grid.ps1      # azd postprovision hook (Windows) — deploys the grid
│   ├── install-selenium-grid.sh       # azd postprovision hook (Linux/macOS)
│   ├── Run-Demo.ps1                   # One-click demo runner (backs the desktop shortcut)
│   └── run-tests.sh                   # Script to execute pytest against the grid (Linux)
└── README.md                          # Project documentation
```

---

## 🚀 Getting Started

This project uses the **[Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/)** to provision infrastructure and deploy Selenium Grid in a single step.

### Prerequisites
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (`azd`)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`), [`kubectl`](https://kubernetes.io/docs/tasks/tools/), and [`helm`](https://helm.sh/docs/intro/install/) on your machine (used by the postprovision hook).
- An active Azure subscription with permissions to create Resource Groups, Virtual Networks, Virtual Machines, and AKS clusters.
- **No SSH key required.** The Windows Jumpbox uses username/password auth — `azd` securely **prompts for the admin password** on first run and stores it in the azd environment (`ADMIN_PASSWORD`).

---

### Step 1: Provision Infrastructure **and** deploy Selenium Grid (azd)

A single command provisions the network, Bastion, Jumpbox, and AKS cluster, then runs the `install-selenium-grid` hook to deploy the grid via Helm:

```powershell
azd auth login
azd up
```

`azd` prompts for an environment name, Azure subscription, and region on first run. What happens:

1. **provision** — deploys [infra/main.bicep](infra/main.bicep) (subscription scope; creates resource group `rg-<env-name>`). azd securely **prompts for the Jumpbox admin password** (`adminPassword`) on first run and stores it as `ADMIN_PASSWORD` (retrieve later with `azd env get-value ADMIN_PASSWORD`).
2. **postprovision hook** — pulls AKS credentials and installs Selenium Grid via Helm. On Windows this runs [scripts/install-selenium-grid.ps1](scripts/install-selenium-grid.ps1); on Linux/macOS it runs [scripts/install-selenium-grid.sh](scripts/install-selenium-grid.sh).

> 💡 **Windows users:** the hooks are configured with both `windows` (PowerShell) and `posix` (sh) variants in [azure.yaml](azure.yaml), so `azd` picks the PowerShell scripts automatically — no bash required.

To re-run only the grid install (e.g. after editing Helm values) without re-provisioning:

```powershell
./scripts/install-selenium-grid.ps1
```

To tear everything down:

```powershell
azd down
```

> ⚠️ **Where the grid install runs — local machine vs. Jumpbox.** The postprovision hook runs **on your machine** and talks to the AKS **public** API server, which works with the default (public) cluster. The Helm step retries automatically to ride out transient network resets (`An existing connection was forcibly closed by the remote host`). If connectivity to the API server stays unreliable — **or** if you enable private-cluster mode (`enablePrivateAksCluster=true`), which makes the API server reachable only from inside the VNet — run the install from the **Jumpbox** instead (see [Step 3](#step-3-alternative-install-the-grid-from-the-jumpbox)). The Jumpbox sits inside the VNet and comes with `az`, `kubectl`, and `helm` pre-installed.

---

### Step 2 (optional): Connect to the Windows Jumpbox via Azure Bastion

The Jumpbox is a **Windows 11 desktop**. Bastion is the **Developer SKU** (no public IP), so you connect through the **Azure Portal** (browser). Grab the password, then connect:

```powershell
azd env get-value ADMIN_PASSWORD   # copy this value
```

1. In the [Azure Portal](https://portal.azure.com), open the Jumpbox VM `vm-sel-aks-jumpbox` (resource group `rg-<your-azd-env-name>`).
2. Select **Connect → Bastion**.
3. Choose **RDP**, set **Username** `azureuser`, paste the password, and click **Connect**.

Once you're on the desktop, `az`, `kubectl`, `helm`, `python`, and `git` are already installed (via a **winget** bootstrap), and a **machine-wide kubeconfig** is configured (`KUBECONFIG=C:\ProgramData\kube\config`) — so `kubectl get nodes` and `helm list -A` work immediately, no login required.

> ℹ️ The Bastion **Developer SKU** is browser-only (single session, same-VNet, no public IP). The native-client CLI commands (`az network bastion ssh` / `tunnel`) require the **Standard** SKU and are not available on Developer.
>
> ⚠️ The Developer SKU is only offered in [select Azure regions](https://learn.microsoft.com/azure/bastion/bastion-overview#sku). If it isn't available in your chosen region, either deploy to a supported region or switch the [bastion module](infra/modules/bastion.bicep) back to the Standard SKU (which adds a public IP).

#### Run commands on the Jumpbox without RDP

You can drive the Windows Jumpbox non-interactively with `az vm run-command` (handy for demos and automation):

```powershell
az vm run-command invoke `
  --resource-group rg-<your-azd-env-name> `
  --name vm-sel-aks-jumpbox `
  --command-id RunPowerShellScript `
  --scripts "hostname; kubectl get pods -n selenium"
```

---

### Step 3 (alternative): Install the Grid from the Jumpbox

Use this instead of the local postprovision hook when the AKS API server is only reachable from inside the VNet (private cluster) or when local connectivity is flaky. From an **RDP session** on the Windows Jumpbox (PowerShell) — the tooling and machine-wide kubeconfig are already set up, so you can deploy the grid directly:

```powershell
helm repo add docker-selenium https://www.selenium.dev/docker-selenium
helm repo update
kubectl create namespace selenium --dry-run=client -o yaml | kubectl apply -f -

git clone https://github.com/<your-org>/aks-seleniumgrid.git
cd aks-seleniumgrid
helm upgrade --install selenium-grid docker-selenium/selenium-grid `
  --namespace selenium --values helm/selenium-grid/values.yaml
```

---

### Step 4: Verify the deployment

**a) Check the pods and the hub service** (works from your machine if the API server is reachable, otherwise run it on the Jumpbox):

```powershell
kubectl get pods -n selenium -o wide
kubectl get svc  -n selenium selenium-grid-selenium-hub
```

Expected: the `selenium-grid-selenium-hub` pod is `1/1 Running`, and the hub `Service` has an **internal** `EXTERNAL-IP` (a private `10.0.4.x` address in the AKS subnet).

> ℹ️ The browser-node pods often show `0/1 READY` even though they work. This is a known docker-selenium chart readiness-probe quirk ("Node is not registered") — the hub's own `/status` is the authoritative signal, which is why the install script waits on that instead of pod readiness.

**b) Confirm the Grid reports ready.** From your machine you can port-forward the hub through the API server (no VNet access needed) and open the Grid Console:

```powershell
kubectl port-forward -n selenium svc/selenium-grid-selenium-hub 4444:4444
# then in a browser: http://localhost:4444/ui/     (live Grid console showing Chrome/Firefox/Edge slots)
# or check readiness:  curl http://localhost:4444/status   -> "ready": true
```

---

### Step 5: Run the UI Tests

Because the hub is exposed on an **internal** load balancer (private IP), the test suite must reach it from **inside the VNet** — connect to the **Windows Jumpbox** via **Bastion → RDP** (username `azureuser`, password from `azd env get-value ADMIN_PASSWORD`), then open **PowerShell**. `python`, `kubectl`, and `git` are already installed and `KUBECONFIG` is set machine-wide. The suite executes against **Chrome**, **Firefox**, and **Edge**:

```powershell
# On the Jumpbox: get the code, then install test deps
git clone https://github.com/<your-org>/aks-seleniumgrid.git
cd aks-seleniumgrid
python -m pip install -r tests/requirements.txt

# Discover the hub's internal IP and run all browsers
$hub = kubectl get svc selenium-grid-selenium-hub -n selenium -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
python -m pytest tests/ `
  --grid-url "http://$hub:4444/wd/hub" `
  --browser-name all `
  --alluredir allure-results `
  --html=test-results/report.html --self-contained-html -v
```

To target a single browser, set `--browser-name chrome` (or `firefox` / `edge`). A complete HTML test report is generated at `test-results/report.html`.

> 💡 On Linux/macOS (or the Linux path) you can instead use [scripts/run-tests.sh](scripts/run-tests.sh), which auto-discovers the hub IP: `./scripts/run-tests.sh "" chrome`.

---

### Step 6: View results & recordings

Four complementary views:

| What | Source | How |
|------|--------|-----|
| **Live execution** | Selenium Grid Console (built in) | While tests run, open `http://<hub>:4444/ui/` (note the trailing slash) and click a session's camera icon to watch it live over noVNC. |
| **Pass/fail report** | pytest-html | Open `test-results/report.html` (self-contained; embeds on-failure screenshots). |
| **Rich report** | Allure | `allure serve allure-results` opens an interactive report (Allure CLI + Java are pre-installed on the Jumpbox). |
| **Session videos** | `selenium/video` sidecar | Every session is recorded to `/videos` inside the node pod; copy them out (below). |

Pull recorded videos off a browser-node pod:

```powershell
kubectl get pods -n selenium
kubectl cp selenium/<node-pod-name>:/videos ./videos
```

---

## 🧪 Test Suite Details
- **Bing Search Tests** ([tests/test_bing.py](tests/test_bing.py)): Navigates to `bing.com`, asserts home page controls, executes search queries, and validates result headers.
- **Google Search Tests** ([tests/test_google.py](tests/test_google.py)): Navigates to `google.com`, handles consent dialogues, executes queries, and asserts results.
- **Parametrized Multi-Browser Execution**: Automatically switches capabilities for Chrome, Firefox, and Edge with screenshot capture on failure.
- **Recording & reporting**: sessions request `se:recordVideo` (captured by the `selenium/video` sidecar) and results feed both **pytest-html** and **Allure**.

---

## 🎬 Demo Script

An end-to-end walkthrough for a live demo. Assumes `azd up` has already provisioned everything and installed the grid. The Jumpbox bootstrap has already **cloned this repo to `C:\Demo\aks-seleniumgrid`** and placed two shortcuts on the desktop.

### 1. Log into the Windows Jumpbox (Azure Bastion → RDP)

```powershell
azd env get-value ADMIN_PASSWORD   # copy the password
```

1. In the [Azure Portal](https://portal.azure.com), open VM **`vm-sel-aks-jumpbox`** (resource group `rg-<your-azd-env-name>`).
2. **Connect → Bastion**, choose **RDP**, **Username** `azureuser`, paste the password, **Connect**.
3. A **Windows 11 desktop** opens in the browser tab.

> Talking point: neither the VM nor the AKS cluster has a public IP — you reached a fully private environment through the Bastion **Developer SKU** (which itself has no public IP).

### 2. Open the live Grid Console

Double-click the **“Selenium Grid”** desktop shortcut — it opens `http://seleniumgrid.dev.lab:4444/ui/` (a private DNS name that resolves, inside the VNet, to the hub's pinned internal IP `10.0.7.100`).

Show the **Chrome / Firefox / Edge** slots registered and ready.

> Talking point: there's no public IP anywhere — the browser reaches the hub over the VNet via a **Private DNS** record. The `/ui/` trailing slash and plain **http** are baked into the shortcut.

### 3. Run the tests — and watch them live

Double-click the **“Run Selenium Demo”** desktop shortcut. It opens PowerShell in `C:\Demo\aks-seleniumgrid`, installs the test deps, and runs the suite across all three browsers via `http://seleniumgrid.dev.lab:4444/wd/hub`.

While it runs, flip to the Grid Console and click a session's **camera icon** to watch the browser drive Bing/Google live over noVNC.

> Prefer a terminal? Everything the shortcut does is in [scripts/Run-Demo.ps1](scripts/Run-Demo.ps1):
> ```powershell
> cd C:\Demo\aks-seleniumgrid
> ./scripts/Run-Demo.ps1                 # all browsers
> ./scripts/Run-Demo.ps1 -Browser chrome # single browser
> ```

### 4. Show the results

```powershell
cd C:\Demo\aks-seleniumgrid
Start-Process test-results/report.html   # pytest-html summary (with failure screenshots)
allure serve allure-results              # rich, interactive Allure report
```

### 5. Show the recordings

```powershell
kubectl get pods -n selenium
kubectl cp selenium/<node-pod-name>:/videos ./videos
# open a .mp4 in .\videos to replay the full session
```

### 6. (Optional) Tear down

```powershell
azd down --purge
```

---

## ⚠️ Notes & Caveats

- **Video recordings are in-pod / ephemeral.** The `selenium/video` sidecar records to a volume inside each browser-node pod, and the recorder image tag tracks the chart default (it is intentionally **not pinned**, so it never conflicts with the pinned `4.26.0-20241101` node images). Videos are lost if a node pod restarts — **copy them out with `kubectl cp` after each run** (see Step 6). For durable retention you'd add an uploader (e.g. to Azure Blob) or a `PersistentVolumeClaim`.
- **Allure depends on the Jumpbox bootstrap succeeding.** The `allure` CLI is installed by the winget bootstrap (Node.js + OpenJDK + `npm install -g allure-commandline`). winget runs in the SYSTEM context and can occasionally fail, in which case `allure serve` won't resolve. The **pytest-html report (`test-results/report.html`) is always produced** and needs nothing extra — treat it as the reliable results view, with Allure as the richer add-on.
  - Bootstrap log: `C:\Windows\Temp\jumpbox-bootstrap.log`. Re-run the bootstrap non-interactively with `az vm run-command invoke --resource-group rg-<env> --name vm-sel-aks-jumpbox --command-id RunPowerShellScript --scripts "<install commands>"`, or just install the missing tool over RDP (e.g. `winget install OpenJS.NodeJS.LTS`).
- **Browser-node pods show `0/1 READY`** even when healthy — a known docker-selenium chart readiness-probe quirk. The hub's `/status` (`"ready": true`) is the authoritative signal.
- **The hub is private** (internal load balancer). Run tests from the Jumpbox, or `kubectl port-forward` the hub to your machine for the Console/`/status`.
- **Bastion Developer SKU** is browser/RDP only (no public IP, single session, same-VNet) and is limited to [certain regions](https://learn.microsoft.com/azure/bastion/bastion-overview#sku); switch the [bastion module](infra/modules/bastion.bicep) to Standard if it's unavailable in yours.
- **The hub IP is pinned** to `10.0.7.100` so the `seleniumgrid.dev.lab` Private DNS A record is stable. This value is set in **two places that must stay in sync**: the `azure-load-balancer-ipv4` annotation in [helm/selenium-grid/values.yaml](helm/selenium-grid/values.yaml) and `hubInternalIp` in [infra/resources.bicep](infra/resources.bicep). The address must be free and within the AKS subnet (`10.0.4.0/22`).
- **Desktop shortcuts & repo clone** are created by the Jumpbox bootstrap (as SYSTEM) on the Public Desktop, and the repo is cloned to `C:\Demo\aks-seleniumgrid`. If the winget/git steps failed, re-run the bootstrap (see the Allure note) or `git clone` manually.
- **Grid Console URL needs the trailing slash + plain http.** Use `http://seleniumgrid.dev.lab:4444/ui/` (or `http://<hub-ip>:4444/ui/`). Without the trailing slash the console's relative assets 404 and the page renders blank; the hub doesn't serve TLS on 4444, so `https://` fails. `/status` is the health check; a browser **GET** to `/wd/hub` returns `"unknown command"` — that's expected (it's the POST-only WebDriver endpoint), not an error.
- **Private DNS resolution** relies on the VNet using default Azure-provided DNS (this template doesn't set custom DNS servers). The `dev.lab` zone uses `.lab` deliberately — the real `.dev` TLD is HSTS-preloaded and would force HTTPS, breaking the plain-http hub.
- **Transient AKS API resets from the local machine.** `azd`/Helm calls to the public API server can hit `An existing connection was forcibly closed`; the postprovision hook retries the Helm step automatically. If it stays flaky, run the grid install from the Jumpbox instead (Step 3).
- **Windows 11 client image licensing.** The Jumpbox uses `MicrosoftWindowsDesktop/windows-11/win11-24h2-pro`, intended for eligible subscriptions. If yours rejects the client SKU, switch the image in [infra/modules/jumpbox.bicep](infra/modules/jumpbox.bicep) to Windows Server with Desktop Experience (no Trusted Launch/TPM changes needed beyond the image reference).

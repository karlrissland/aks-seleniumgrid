# Copilot Agent Instructions for AKS Selenium Grid

## Project Overview
This repository contains Infrastructure as Code (Bicep), Helm chart configurations, automation scripts, and automated UI test suites (Python pytest + Selenium WebDriver) to deploy and run **Selenium Grid on Azure Kubernetes Service (AKS)** within a private, VNet-isolated environment accessed securely via a jumpbox and Azure Bastion.

## Architecture Guidelines
- **Infrastructure as Code**: Modular Azure Bicep (`infra/` directory).
  - VNet segmentation: `AzureBastionSubnet`, `AksSubnet`, `JumpboxSubnet`.
  - AKS: 2-node cluster with system/user-assigned managed identity, Azure CNI Overlay, and RBAC enabled.
  - Jumpbox: Windows 11 desktop VM (username/password auth) with a winget bootstrap that installs tooling (`az`, `kubectl`, `helm`, `python`, `git`) and configures a machine-wide kubeconfig.
  - Bastion: Developer SKU (no public IP), browser/RDP access to the Jumpbox.
  - Security: Isolated networking, no public IP directly attached to AKS or Jumpbox, accessed via Azure Bastion.
- **Selenium Grid Deployment**:
  - Official Helm chart: `selenium-grid` from `https://www.selenium.dev/docker-selenium`.
  - Components: Hub (or distributed router/distributor), Chrome Node, Firefox Node, and Edge Node.
  - Service Exposure: ClusterIP or Internal LoadBalancer within the VNet.
- **Testing Architecture**:
  - Python 3 with `pytest` and `selenium` remote webdriver.
  - Tests connect to `http://<selenium-hub-ip-or-dns>:4444/wd/hub` or `http://selenium-grid-hub.selenium.svc.cluster.local:4444`.
  - Parametrized tests covering Chrome, Firefox, and Edge on target sites (`bing.com` and `google.com`).

## Development & Maintenance Conventions
- Keep Bicep modules decoupled and parameterized (`main.bicep` as entry point).
- Keep Helm configuration (`helm/selenium-grid/values.yaml`) clean with tuned resource limits, health probes, and replica counts.
- Ensure test suites are parallel-safe, generate clear JUnit/HTML reports, and capture artifacts on failure.
- Validate Bicep templates using `az bicep build` and ensure test code follows clean standard Python conventions.

# AKS Standard vs. AKS Automatic — Conversion Assessment

**Context:** This repository provisions a private, VNet-isolated AKS cluster (via Bicep) and installs
Selenium Grid on it with Helm. This document evaluates what would change if we converted the current
**AKS Standard** cluster ([infra/modules/aks.bicep](infra/modules/aks.bicep)) to the **AKS Automatic**
SKU. It is a decision aid only — no change has been made.

> **Bottom line:** The Selenium Grid workload *would* still run on AKS Automatic, but it is **not** a
> zero-change, capability-preserving swap. We would trade away fine-grained node control and cost
> predictability, inherit enforced security policy that likely requires Helm chart edits, and move to a
> higher-cost tier. It is a "convert with a few required edits," not a drop-in replacement.

---

## Quick verdict

| Question | Answer |
| --- | --- |
| Can it run our private, VNet-integrated design? | **Yes** — with our own custom VNet + Private DNS (which Automatic *requires* when private). |
| Does it preserve all current capabilities unchanged? | **No** — see trade-offs below. |
| Is it a drop-in swap? | **No** — cluster must be created fresh; no in-place Standard → Automatic migration. |
| Would our Helm chart deploy as-is? | **Probably not** — enforced policy needs resource requests/limits + compliant security context. |

---

## What we would LOSE or hand over to Azure

### 1. Fixed 2-node pool → node autoprovisioning
Today [infra/modules/aks.bicep](infra/modules/aks.bicep) pins:
- `nodeCount: 2`
- `enableAutoScaling: false`
- `nodeVmSize: 'Standard_D4s_v5'`

AKS Automatic replaces this with **node autoprovisioning** (Karpenter-based). Azure decides the node
count and VM size from pending pod requests and can scale toward zero. The repo's documented
"2-node cluster" invariant no longer holds, and running cost becomes less predictable.

### 2. Hand-managed system node pool
System nodes on Automatic are **AKS-hosted and managed** (Azure Linux). We can no longer size or
configure the system pool in Bicep the way we do now.

### 3. Enforced guardrails (most likely to break our install)
Automatic turns on **Deployment Safeguards + baseline Pod Security Standards in *enforce* mode** by
default (via Azure Policy). Our Selenium Grid chart ([helm/selenium-grid/values.yaml](helm/selenium-grid/values.yaml))
would need:
- CPU and memory **requests and limits** on every component (Hub, Chrome, Firefox, Edge nodes).
- A compliant **security context** (non-privileged, non-root where enforced).

Otherwise the policy will mutate or reject the pods. This is the change most likely to require actual
work before the grid comes up cleanly.

---

## What CHANGES but is functionally fine

### Networking dataplane → Cilium
Automatic uses **Azure CNI Overlay powered by Cilium** instead of our current
`networkPolicy: 'azure'` on overlay. Functionally equivalent for the grid's east-west traffic.

### Private / VNet integration is preserved
We keep our **custom VNet + Private DNS** ([infra/modules/privatedns.bicep](infra/modules/privatedns.bicep)),
which Automatic **requires** for private scenarios because the managed node resource group (`MC_...`) is
locked and cannot host VNet links on the default Private DNS zone. Our `enablePrivateCluster` intent
maps to **API server VNet integration**, which is preconfigured on Automatic.

### Identity features we already use
- **OIDC issuer** — preconfigured on Automatic (we enable it today).
- **Workload Identity** — preconfigured on Automatic (we enable it today).

---

## What we would GAIN (whether we want it or not)

- **Forced Standard tier** with a paid uptime SLA (our current cluster runs a lower default tier).
- Always-on add-ons: **Managed Prometheus, Container Insights, image cleaner, KEDA, VPA, and
  app-routing ingress** (NGINX / Gateway API depending on version).
- A **pod readiness SLA** (99.9% of qualifying pod-readiness ops within 5 minutes).

These add capability but also raise the **baseline monthly cost** versus our current default-tier,
2-node setup.

---

## Hard constraints / blockers

- **No Windows nodes** on Automatic.
- **No in-place migration** — an Automatic cluster must be created fresh (new cluster, redeploy grid).
- **Node resource group is locked** — no custom changes to `MC_*` resources (drives the custom
  VNet + Private DNS requirement above).

---

## Mapping: current settings → Automatic behavior

| Current setting (`aks.bicep`) | Under AKS Automatic |
| --- | --- |
| `sku` (implicit Standard/managedCluster) | `sku.name: 'Automatic'` |
| `nodeCount: 2`, `enableAutoScaling: false` | Removed — node autoprovisioning manages nodes |
| `nodeVmSize: 'Standard_D4s_v5'` | Chosen dynamically by autoprovisioning |
| `agentPoolProfiles` (System pool, hand-defined) | Managed/hosted system node pool |
| `networkPlugin: azure`, `networkPluginMode: overlay`, `networkPolicy: azure` | Azure CNI Overlay powered by Cilium (default) |
| `apiServerAccessProfile.enablePrivateCluster` | API server VNet integration (preconfigured) |
| Custom VNet (`vnetSubnetID`) | Supported (custom VNet) — **required** for private |
| Private DNS module | **Required** (managed DNS zone is locked) |
| `oidcIssuerProfile.enabled: true` | Preconfigured |
| `securityProfile.workloadIdentity.enabled: true` | Preconfigured |
| Default cluster tier | Forced Standard tier (paid uptime SLA) |
| (none) | Enforced Deployment Safeguards + baseline Pod Security Standards |

---

## If we decide to proceed — required work

1. **Rewrite the AKS module** to `sku.name: 'Automatic'`, remove the fixed `agentPoolProfiles`
   sizing, and keep the custom VNet + Private DNS wiring.
2. **Add resource requests/limits and a compliant security context** to
   [helm/selenium-grid/values.yaml](helm/selenium-grid/values.yaml) to satisfy enforced policy.
3. **Re-validate cost** — factor in Standard tier + always-on observability/add-ons.
4. **Fresh deployment** — provision a new cluster and redeploy the grid (no in-place upgrade path).
5. **Adjust repo docs** that assume a fixed 2-node cluster.

---

*Sources: Microsoft Learn — "Introduction to AKS Automatic" and "Create an AKS Automatic cluster"
(feature comparison, networking defaults, limitations). Verified 2026-09-24.*

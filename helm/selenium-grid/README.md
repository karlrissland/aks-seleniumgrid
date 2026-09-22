# Selenium Grid Helm Deployment on AKS

This folder contains the Helm deployment configuration for **Selenium Grid 4** running on Azure Kubernetes Service (AKS).

## Official Helm Chart Information
- **Chart Name**: `selenium-grid`
- **Repository URL**: `https://www.selenium.dev/docker-selenium`
- **Official Documentation**: [https://github.com/SeleniumHQ/docker-selenium](https://github.com/SeleniumHQ/docker-selenium)

## Deployment Steps

### 1. Connect to AKS from the Jumpbox VM
```bash
az login --identity
az aks get-credentials --resource-group <RESOURCE_GROUP_NAME> --name <AKS_CLUSTER_NAME>
```

### 2. Add the Selenium Helm Repository
```bash
helm repo add docker-selenium https://www.selenium.dev/docker-selenium
helm repo update
```

### 3. Deploy Selenium Grid in a dedicated namespace
```bash
# Create namespace
kubectl create namespace selenium --dry-run=client -o yaml | kubectl apply -f -

# Deploy with custom values
helm upgrade --install selenium-grid docker-selenium/selenium-grid \
  --namespace selenium \
  --values helm/selenium-grid/values.yaml
```

### 4. Verify the Deployment
```bash
# Check pod status (Hub, Chrome, Firefox, Edge nodes)
kubectl get pods -n selenium -o wide

# Check the Internal LoadBalancer IP assigned to the Hub
kubectl get svc -n selenium
```

### 5. Accessing the Selenium Grid Console UI
From within the Jumpbox VM:
- Open a browser or run `curl http://<INTERNAL_LB_IP>:4444/status`
- You can also view the web UI at `http://<INTERNAL_LB_IP>:4444/ui/` (keep the trailing slash, and use plain http — otherwise the console assets 404 and the page is blank)

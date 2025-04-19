# Istio Ambient Mesh Performance Demo (KubeCon Europe 2025)

https://www.youtube.com/watch?v=oi4TpxuIYXk

This repository contains the scripts and configuration to run a performance comparison demo showcasing Istio's Ambient Mesh mode versus the traditional sidecar model and a baseline without Istio. The demo was designed for/presented at KubeCon Europe.

The demo utilizes:
*   **KinD:** To create a local Kubernetes cluster.
*   **Helm:** To install Istio, Prometheus, Grafana, Kiali, and other tooling.
*   **Istio:** Specifically demonstrating the Ambient Mesh profile (`ztunnel`, `waypoint proxy`) and comparing it with sidecars.
*   **kube-prometheus-stack:** For collecting metrics.
*   **Grafana:** For visualizing performance metrics, using Prometheus Native Histograms.
*   **k6 & k6-operator:** To generate load and run performance tests.
*   **Gateway API:** For configuring Istio routing (HTTPRoute).
*   **Fortio:** As the backend service receiving traffic during tests.

## Demo Scenario

The script performs the following steps:

1.  Sets up a KinD Kubernetes cluster.
2.  Installs necessary monitoring tools (Prometheus, Grafana, k6-operator).
3.  Installs Istio using the `ambient` profile.
4.  Installs Kiali for mesh visualization.
5.  Deploys backend applications (`fortio`) in three configurations:
    *   `not-in-mesh`: No Istio components involved.
    *   `in-mesh`: Traditional Istio sidecar injected.
    *   `in-ambient`: Part of the Ambient mesh (initially only ztunnel).
6.  Runs a series of `k6` performance tests against the different backend configurations:
    *   **Baseline:** Traffic to `not-in-mesh`.
    *   **Sidecar:** Traffic to `in-mesh`.
    *   **Sidecar + L7 Policy:** Traffic to `in-mesh` with an `HTTPRoute` applied.
    *   **Ambient:** Traffic to `in-ambient` (ztunnel only).
    *   **Ambient + Waypoint:** Traffic to `in-ambient` with a Waypoint Proxy and an `HTTPRoute` applied.
7.  Each test phase is annotated in Grafana for easy comparison.

## Prerequisites

Before running the demo, ensure you have the following tools installed and configured:

*   **`kubectl`:** Kubernetes command-line tool.
*   **`helm`:** Kubernetes package manager (v3+ recommended).
*   **`kind`:** Kubernetes IN Docker (v0.18+ recommended for better Gateway API support).
*   **`curl`:** Command-line tool for transferring data with URLs.
*   **`bash`:** The script is written for bash.
*   **`git`:** To clone this repository.
*   **Docker:** Required by KinD to run Kubernetes nodes as containers.
*   **Sufficient Local Resources:** KinD and the demo workloads require a reasonable amount of CPU, Memory, and Disk space. Recommend at least 8GB RAM and 4+ CPU cores available to Docker.

## Setup

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/djannot/kubecon-london-2025.git
    cd kubecon-london-2025
    ```
2.  **Ensure Helper Scripts are Executable:**
    If the `scripts` directory exists and contains `deploy-cluster1.sh` and `check.sh`, make them executable:
    ```bash
    chmod +x scripts/*.sh
    ```
3.  **Ensure Grafana Dashboard JSON is Present:**
    Make sure the `k6-native-histograms.json` file (or the name referenced in the main script) exists in the root directory.

## Running the Demo

Execute the main demo script:

```bash
bash ./kubecon-demo.sh
```

**Note:** The script performs many installations, waits for resources to become ready, and runs multiple performance tests (each lasting 2+ minutes). The entire process can take a significant amount of time (e.g., 20-30 minutes or more depending on your machine and network speed). Monitor the output for progress and potential errors.

## Viewing Results

Once the script completes successfully:

1.  **Access Grafana:**
    *   The script attempts to set up Grafana with a `LoadBalancer` service. Find its external IP/port.
    *   Login using the credentials:
        *   Username: `admin`
        *   Password: `prom-operator`

2.  **Open the k6 Dashboard:**
    *   Navigate to Dashboards -> Browse.
    *   Find and open the k6 dashboard.

3.  **Analyze Performance:**
    *   The dashboard displays various metrics from the k6 tests (request rate, duration percentiles p95/p99, etc.) and potentially system metrics.
    *   Look for the **Annotations** on the time graphs. The script automatically adds annotations marking the start and end of each test phase: "Baseline", "Sidecars", "Sidecars with L7 policy", "Ambient", "Ambient with waypoint".
    *   Compare the performance metrics (especially latency - `http_req_duration`) across these different annotated time ranges to observe the overhead differences between the configurations.

4.  **(Optional) Access Kiali:**
    *   Kiali is also exposed via a LoadBalancer. Find its IP/port.
    *   Explore the service graph and application details.

## Cleanup

To remove all resources created by the demo script, delete the KinD cluster:

```bash
kind delete cluster --name cluster1
```

You might also want to remove the downloaded Istio directory if it remains:

```bash
rm -rf istio-*
```

## Customization

*   **k6 Load:** Modify the `scenarios` section within the `k6-test.js` ConfigMap definitions in the main script to change the load pattern (rate, duration, VUs).
*   **Resource Allocation:** Adjust `resources.limits` and `resources.requests` for the k6 runner pods or other deployments if needed.
*   **Istio Version:** Uupdate Helm chart versions.
*   **Tooling Versions:** Update Helm chart versions for Prometheus, Grafana, etc., but be mindful of potential compatibility issues (especially with the k6 Prometheus remote write format or native histograms).
```

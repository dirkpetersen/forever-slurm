# forever-slurm
Use Traefik to keep highly available (web)services running forever on an HPC cluster managed by Slurm

```mermaid
graph LR
    style A fill:#f9f,stroke:#333,stroke-width:4px
    style B fill:#bbf,stroke:#333,stroke-width:4px
    style C fill:#bfb,stroke:#333,stroke-width:2px
    style D fill:#bfb,stroke:#333,stroke-width:2px

    subgraph Outside HPC
        A[Web Server]
    end
    subgraph HPC Cluster
        B[Login Node with Traefik<br/>(Port 13013)]
        C[Worker HPC Node 1<br/>(Random Port X)]
        D[Worker HPC Node 2<br/>(Random Port Y)]
    end
    A --|SSH Port Forwarding<br/>to Port 13013| B
    B --|Load Balancing / Failover| C
    B --|Load Balancing / Failover| D

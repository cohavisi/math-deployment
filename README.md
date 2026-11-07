# Math GitOps deployment

`application.yaml` configures Argo CD to synchronize the `dev` directory into
the `myapp` namespace. `dev/deployment.yaml` runs five replicas of the math
application; `dev/service.yaml` exposes them through a NodePort Service on
port 8080.

## Health probes

All probes contact the application's named `http` port (8080) directly:

| Probe | Endpoint | Interval | Timeout | Consecutive failures |
| --- | --- | --- | --- | --- |
| Startup | `/health/startup` | 5 seconds | 2 seconds | 24 |
| Readiness | `/health/ready` | 5 seconds | 2 seconds | 1 |
| Liveness | `/health/live` | 10 seconds | 2 seconds | 3 |

Startup permits approximately two minutes of initialization. Until it succeeds,
readiness and liveness are disabled. They then run independently. Readiness
failure removes the Pod from normal Service routing; startup or liveness failure
at its threshold triggers a container restart. Timing is approximate and includes
kubelet scheduling and the container's termination grace period.

The math application implements these endpoints in `handlers/health.go`.
Initialization is synchronous and there are no external dependencies, so each
endpoint confirms that the HTTP server is serving and returns HTTP 200.

## Publish before synchronizing

The Deployment still references the existing pinned image. It must be replaced
with an image built from the math application changes before these probes are
synchronized; an older image without the endpoints will fail its startup probe.

1. Commit and push the application changes to `math`'s `main` branch.
2. Wait for its GitHub Actions workflow to pass and publish
   `docker.io/cohavisi/mymath:<application-commit-sha>`.
3. Update `dev/deployment.yaml`'s `image` to that published tag.
4. Commit and push the GitOps changes. Argo CD then applies the Deployment and
   Service from `dev`.

The Service needs no probe settings: it uses Pod readiness automatically.

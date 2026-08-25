# Capacity planning

This page gives self-hosters conservative `MAX_SECRETS` starting points for VPSes with 4, 8, 12, or 16
GiB of total RAM. It is evidence from a reproducible constrained load test, not a promise that every VPS,
kernel, CPU, or future Burnerpad/OTP release will behave identically.

## Recommended profiles

Each profile assigns 75% of total VPS RAM to the Burnerpad app container and reserves 25% for the host OS,
Docker, cloudflared, and monitoring. The workload must stay at or below 85% of the app container's exact
byte limit, leaving both app-level and host-level headroom.

| Total VPS RAM | App limit | `MAX_SECRETS` | Raw ciphertext at capacity | Container peak | Peak / app limit |
|---:|---:|---:|---:|---:|---:|
| 4 GiB | 3 GiB | 24,000 | 1.465 GiB | 2.458 GiB | 81.94% |
| 8 GiB | 6 GiB | 50,000 | 3.052 GiB | 4.930 GiB | 82.17% |
| 12 GiB | 9 GiB | 75,000 | 4.578 GiB | 7.304 GiB | 81.16% |
| 16 GiB | 12 GiB | 100,000 | 6.104 GiB | 9.649 GiB | 80.41% |

`MAX_SECRETS` is a row-count ceiling. The table deliberately fills every row with the maximum accepted
65,536-byte opaque ciphertext, so ordinary deployments with smaller ciphertexts should use less memory at
the same row count. Do not increase the row count merely because current traffic uses small secrets: an
attacker can submit maximum-size valid blobs. Burnerpad currently boot-validates `MAX_SECRETS` to at most
100,000, so the 16 GiB profile reaches the supported configuration ceiling.

## Test method

The evidence below was collected on 2026-08-24 from application revision
`48f031ed276ac90c9e8e9e8e254a61eb2729bea8`. The host had 64 GiB RAM and 32 CPUs; each production app
container was constrained to the memory shown above, no additional swap, and 4 CPUs. This accurately
exercises the app's cgroup/OOM boundary and leaves the intended memory reserve, but it does not reproduce
every source of contention on a physically smaller VPS. Throughput and latency are therefore reference
measurements, not sizing promises.

The pinned Node 24.19.0 load client used the internal production backend network, 64 concurrent workers,
one-day TTLs, unique benchmark source addresses, and only public HTTP endpoints. For each profile it:

1. filled the store to `MAX_SECRETS` with maximum-size ciphertexts;
2. required 256 additional valid creates to return `503` at capacity;
3. probed readiness and public stats 256 times while full;
4. concurrently revealed 1,000 rows and revoked 1,000 rows with their management tokens;
5. refilled all 2,000 freed slots and required capacity rejection again;
6. stopped mutation load, waited one second, then required 256 recovery probes to succeed;
7. sampled public queue/busy/error metrics every 100 ms and read final BEAM, ETS, and cgroup memory.

Every phase had zero request timeouts, unexpected statuses, throttles, busy responses, and internal errors.
Mutation p99 had to remain below 2 seconds, probe p99 below 1 second, peak container memory at or below 85%
of its limit, and both state-server queues had to return to zero after the load stopped.

## Results

Fill is the longest and most memory-intensive phase. Its measurements provide the most comparable latency
and throughput figures across the profiles:

| VPS profile | Fill requests | Throughput | p50 | p95 | p99 | Max |
|---:|---:|---:|---:|---:|---:|---:|
| 4 GiB | 24,000 | 682.18 req/s | 90.97 ms | 144.70 ms | 184.56 ms | 358.89 ms |
| 8 GiB | 50,000 | 819.66 req/s | 75.76 ms | 121.82 ms | 145.35 ms | 283.02 ms |
| 12 GiB | 75,000 | 755.02 req/s | 82.92 ms | 130.74 ms | 155.77 ms | 291.05 ms |
| 16 GiB | 100,000 | 723.53 req/s | 86.18 ms | 137.44 ms | 161.61 ms | 310.89 ms |

Runtime and recovery evidence:

| VPS profile | Final BEAM memory | Peak admission queue | Peak create queue | Recovery-probe p99 | Final queues |
|---:|---:|---:|---:|---:|---:|
| 4 GiB | 1.559 GiB | 10 | 6 | 11.76 ms | 0 / 0 |
| 8 GiB | 3.163 GiB | 40 | 12 | 10.69 ms | 0 / 0 |
| 12 GiB | 4.706 GiB | 64 | 18 | 24.29 ms | 0 / 0 |
| 16 GiB | 6.248 GiB | 39 | 23 | 9.27 ms | 0 / 0 |

All 256 at-capacity creates and all 256 post-refill creates returned the expected `503`. All readiness,
stats, reveal, revoke, refill, and recovery requests returned the expected `200`. Final resident count
equalled configured capacity in every profile; admission/create queues recovered to zero, and the busy,
throttled, and internal-error counters remained zero.

Calibration rejected two less conservative settings:

- 60,000 rows on the 8 GiB profile reached 97% of the 6 GiB app limit. Functional behavior remained
  correct, but the memory headroom was unacceptable.
- 25,000 rows on the 4 GiB profile reached 85.27% of the 3 GiB app limit. The exact-byte gate rejects it;
  24,000 rows passed at 81.94%.

## Reproduce it

Build the production image, install the repository's pinned Ansible runtime, and run either one profile or
the complete matrix:

```bash
docker build --build-arg BURNERPAD_REVISION="$(git rev-parse HEAD)" -t burnerpad:capacity .
python3 -m pip install --disable-pip-version-check ansible-core==2.21.3

# One profile (defaults to 8 GiB / 6 GiB app / 50,000 rows):
test/load/run_capacity_profile.sh burnerpad:capacity burnerpad:capacity

# All four profiles; JSON phase reports and runtime-memory sidecars are written here:
LOAD_MATRIX_REPORT_DIR=/tmp/burnerpad-capacity-reports \
  test/load/run_capacity_matrix.sh burnerpad:capacity burnerpad:capacity
```

The second image argument exists because the harness renders the real two-service production Compose
template; it starts only the app service, so reusing the app image there is safe. The complete matrix needs
a Docker host with at least 16 GiB RAM. `LOAD_MAX_MEMORY_PERCENT`, `LOAD_CONCURRENCY`, and the phase-size
environment variables may be tightened for local investigation, but changing them makes results
non-comparable with this evidence.

Rerun the matrix on the intended VPS class before raising `MAX_SECRETS`, after an Erlang/OTP or dependency
upgrade, or after changing Store/Abuse behavior. Monitor real cgroup memory and leave the host reserve in
place; never assign all VPS RAM to the app container.

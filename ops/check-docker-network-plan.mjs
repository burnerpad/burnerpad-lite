// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

import { readFileSync } from "node:fs";

const configurationFailure = () => {
  process.stderr.write("Unable to validate the Docker backend network plan.\n");
  process.exit(2);
};

const parseAddress = (value) => {
  const octets = value.split(".");

  if (octets.length !== 4 || octets.some((octet) => !/^(0|[1-9][0-9]{0,2})$/.test(octet))) {
    throw new Error("invalid IPv4 address");
  }

  const numbers = octets.map(Number);
  if (numbers.some((octet) => octet > 255)) throw new Error("invalid IPv4 octet");

  return numbers.reduce((address, octet) => (address << 8n) | BigInt(octet), 0n);
};

const formatAddress = (value) =>
  [24n, 16n, 8n, 0n].map((shift) => Number((value >> shift) & 255n)).join(".");

const parseCidr = (value, { target = false } = {}) => {
  if (typeof value !== "string") throw new Error("CIDR must be a string");

  const parts = value.split("/");
  if (parts.length !== 2 || !/^(0|[1-9][0-9]?)$/.test(parts[1])) {
    throw new Error("invalid IPv4 CIDR");
  }

  const prefix = Number(parts[1]);
  if (prefix > 32 || (target && (prefix < 16 || prefix > 29))) {
    throw new Error("unsupported IPv4 prefix");
  }

  const address = parseAddress(parts[0]);
  const hostBits = 32 - prefix;
  const size = 1n << BigInt(hostBits);
  const start = (address / size) * size;
  const end = start + size - 1n;

  if (target && address !== start) throw new Error("target CIDR is not canonical");

  return { start, end, prefix, canonical: `${formatAddress(start)}/${prefix}` };
};

const isPrivate = ({ start, end }) =>
  ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
    .map((cidr) => parseCidr(cidr))
    .some((range) => start >= range.start && end <= range.end);

const overlaps = (left, right) => left.start <= right.end && right.start <= left.end;
const safeNetworkName = (value) =>
  typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(value) ? value : "unavailable";

try {
  const [targetValue, project, logicalName, extra] = process.argv.slice(2);
  if (
    extra !== undefined ||
    !/^[a-z0-9][a-z0-9_-]{0,62}$/.test(project ?? "") ||
    !/^[a-z0-9][a-z0-9_-]{0,62}$/.test(logicalName ?? "")
  ) {
    configurationFailure();
  }

  const target = parseCidr(targetValue, { target: true });
  if (!isPrivate(target)) configurationFailure();

  const input = readFileSync(0, "utf8");
  if (Buffer.byteLength(input, "utf8") > 1024 * 1024) configurationFailure();

  const inventory = JSON.parse(input);
  if (!Array.isArray(inventory)) configurationFailure();

  let reusable = false;

  for (const network of inventory) {
    if (network === null || typeof network !== "object" || Array.isArray(network)) configurationFailure();

    const labels = network.Labels ?? {};
    const configs = network.IPAM?.Config ?? [];
    if (labels === null || typeof labels !== "object" || !Array.isArray(configs)) configurationFailure();

    for (const config of configs) {
      if (config === null || typeof config !== "object" || typeof config.Subnet !== "string") {
        configurationFailure();
      }

      // The backend plan is IPv4-only. IPv6 allocations cannot overlap it.
      if (config.Subnet.includes(":")) continue;

      const allocated = parseCidr(config.Subnet);
      if (!overlaps(target, allocated)) continue;

      const ownedBackend =
        labels["com.docker.compose.project"] === project &&
        labels["com.docker.compose.network"] === logicalName &&
        allocated.canonical === target.canonical;

      if (ownedBackend) {
        reusable = true;
        continue;
      }

      process.stderr.write(
        `Docker backend subnet overlaps network=${safeNetworkName(network.Name)} allocated=${allocated.canonical}.\n`
      );
      process.exit(10);
    }
  }

  const disposition = reusable ? "reusable" : "available";
  process.stdout.write(`Docker backend subnet is ${disposition} target=${target.canonical}.\n`);
} catch {
  configurationFailure();
}

/**
 * Adds to `@mccormick/omni/inventory` the one view Omni's own resources lack:
 * what is on each machine's disks. For one cluster it fetches the machines'
 * node IPs from Omni, mints a cluster talosconfig for the service account
 * (`omnictl talosconfig`), and asks every node through Omni's Talos proxy for
 * its disks, discovered partitions and `/var` usage, in one execution. One
 * `volumeLayout` resource per node: system disk, partitions by label,
 * unallocated space, and how full EPHEMERAL is. Read-only.
 *
 * Both `omnictl` and `talosctl` authenticate with `OMNI_SERVICE_ACCOUNT_KEY`
 * in the environment; the talosconfig is a temporary file removed afterwards
 * and never merged into `~/.talos/config`.
 *
 * @module
 */
import { z } from "npm:zod@4";

const VolumesArgsSchema = z.object({
  cluster: z.string().min(1).describe(
    "Omni cluster name, e.g. dataverket-prod",
  ),
  talosctlPath: z.string().default("talosctl").describe(
    "Path to the talosctl binary; override when it is not on PATH",
  ),
});
type VolumesArgs = z.infer<typeof VolumesArgsSchema>;

const DiskSchema = z.object({
  devPath: z.string(),
  sizeBytes: z.number(),
  transport: z.string(),
  rotational: z.boolean(),
  systemDisk: z.boolean(),
  serial: z.string().optional(),
  model: z.string().optional(),
});

const PartitionSchema = z.object({
  devPath: z.string(),
  parentDevPath: z.string(),
  index: z.number().int(),
  label: z.string().describe("GPT partition label, e.g. EPHEMERAL or u-<name>"),
  filesystem: z.string().describe("Probed filesystem, or empty"),
  sizeBytes: z.number(),
});

export const VolumeLayoutSchema = z.object({
  hostname: z.string(),
  nodeIp: z.string(),
  machineId: z.string(),
  cluster: z.string(),
  role: z.string(),
  disks: z.array(DiskSchema),
  partitions: z.array(PartitionSchema),
  systemDisk: z.string().describe("Device path of the disk holding STATE"),
  systemDiskSizeBytes: z.number(),
  systemDiskUnallocatedBytes: z.number().describe(
    "Bytes on the system disk not covered by any partition",
  ),
  ephemeralSizeBytes: z.number(),
  ephemeralUsedBytes: z.number().describe("Bytes used under /var"),
  ephemeralUsedPercent: z.number(),
  ephemeralLibBytes: z.number().describe("/var/lib: images, kubelet, etcd"),
  ephemeralLogBytes: z.number(),
  userVolumes: z.array(z.string()).describe("Names of u-<name> partitions"),
  timestamp: z.string(),
});
export type VolumeLayout = z.infer<typeof VolumeLayoutSchema>;

interface GlobalArgs {
  endpoint: string;
  serviceAccountKey: string;
  insecureSkipTlsVerify?: boolean;
  omnictlPath?: string;
}

/** Result of one tool invocation. */
export interface ExecResult {
  code: number;
  stdout: string;
  stderr: string;
}
/** Runs a tool with the given environment; replaceable so tests never spawn. */
export type Exec = (
  argv: string[],
  env: Record<string, string>,
  signal?: AbortSignal,
) => Promise<ExecResult>;

const denoExec: Exec = async (argv, env, signal) => {
  const out = await new Deno.Command(argv[0], {
    args: argv.slice(1),
    env: { ...Deno.env.toObject(), ...env },
    signal,
    stdin: "null",
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: out.code,
    stdout: new TextDecoder().decode(out.stdout),
    stderr: new TextDecoder().decode(out.stderr),
  };
};
let exec: Exec = denoExec;
/** Test seam: replace the subprocess runner. */
export function setRuntime(e: Exec): void {
  exec = e;
}

/** A `{metadata, spec}` record as `omnictl get -o json` and `talosctl get -o json` print them. */
export interface Record_ {
  metadata: { id: string; labels?: Record<string, unknown> };
  node?: string;
  spec: Record<string, unknown>;
}

/** Parse concatenated pretty-printed JSON objects (no array wrapper). */
export function parseConcatJson(text: string): Record_[] {
  const t = text.trim();
  if (t === "") return [];
  if (t.startsWith("[")) return JSON.parse(t) as Record_[];
  const out: Record_[] = [];
  let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === "{") {
      if (depth === 0) start = i;
      depth++;
    } else if (c === "}") {
      depth--;
      if (depth === 0 && start >= 0) {
        out.push(JSON.parse(t.slice(start, i + 1)) as Record_);
        start = -1;
      }
    }
  }
  if (depth !== 0) throw new Error("unbalanced JSON output");
  return out;
}

/**
 * Parse `talosctl -n a,b usage -d 1 /var`: a header then `NODE SIZE NAME` rows.
 * Returns bytes per node for `.` (total), `lib` and `log`.
 */
export function parseUsage(
  text: string,
): Record<string, { total: number; lib: number; log: number }> {
  const res: Record<string, { total: number; lib: number; log: number }> = {};
  for (const line of text.split("\n")) {
    const cols = line.trim().split(/\s+/);
    if (cols.length !== 3 || cols[0] === "NODE") continue;
    const [node, size, name] = cols;
    const n = Number(size);
    if (!Number.isFinite(n)) continue;
    res[node] ??= { total: 0, lib: 0, log: 0 };
    if (name === ".") res[node].total = n;
    else if (name === "lib") res[node].lib = n;
    else if (name === "log") res[node].log = n;
  }
  return res;
}

/** One machine of the cluster as Omni identifies it. */
export interface Member {
  machineId: string;
  hostname: string;
  nodeIp: string;
  role: string;
}

/** Cluster members from `omnictl get clustermachineidentity -o json`. */
export function members(records: Record_[], cluster: string): Member[] {
  const out: Member[] = [];
  for (const r of records) {
    const labels = r.metadata.labels ?? {};
    if (labels["omni.sidero.dev/cluster"] !== cluster) continue;
    const ips = (r.spec.nodeips as string[] | undefined) ?? [];
    if (ips.length === 0) continue;
    out.push({
      machineId: r.metadata.id,
      hostname: String(r.spec.nodename ?? r.metadata.id),
      nodeIp: ips[0],
      role: "omni.sidero.dev/role-controlplane" in labels
        ? "controlplane"
        : "worker",
    });
  }
  return out.sort((a, b) => a.hostname.localeCompare(b.hostname));
}

/** Combine one node's disks, discovered volumes and usage into its layout. */
export function buildLayout(
  m: Member,
  cluster: string,
  disks: Record_[],
  volumes: Record_[],
  usage: { total: number; lib: number; log: number } | undefined,
  now: string,
): VolumeLayout {
  const parts: z.infer<typeof PartitionSchema>[] = volumes
    .filter((v) => v.spec.partition_label !== undefined)
    .map((v) => ({
      devPath: String(v.spec.dev_path),
      parentDevPath: String(v.spec.parent_dev_path ?? ""),
      index: Number(v.spec.partition_index ?? 0),
      label: String(v.spec.partition_label),
      filesystem: String(v.spec.name ?? ""),
      sizeBytes: Number(v.spec.size ?? 0),
    }))
    .sort((a, b) =>
      a.parentDevPath.localeCompare(b.parentDevPath) || a.index - b.index
    );
  const systemDisk = parts.find((p) => p.label === "STATE")?.parentDevPath ??
    "";
  const realDisks = disks.filter((d) =>
    !String(d.spec.dev_path).startsWith("/dev/loop") && d.spec.cdrom !== true
  );
  const ds: z.infer<typeof DiskSchema>[] = realDisks.map((d) => ({
    devPath: String(d.spec.dev_path),
    sizeBytes: Number(d.spec.size ?? 0),
    transport: String(d.spec.transport ?? ""),
    rotational: d.spec.rotational === true,
    systemDisk: String(d.spec.dev_path) === systemDisk,
    serial: d.spec.serial ? String(d.spec.serial) : undefined,
    model: d.spec.model ? String(d.spec.model) : undefined,
  })).sort((a, b) => a.devPath.localeCompare(b.devPath));
  const sysSize = ds.find((d) => d.systemDisk)?.sizeBytes ?? 0;
  const sysParts = parts.filter((p) => p.parentDevPath === systemDisk);
  const allocated = sysParts.reduce((s, p) => s + p.sizeBytes, 0);
  const eph = parts.find((p) => p.label === "EPHEMERAL");
  const ephSize = eph?.sizeBytes ?? 0;
  const used = usage?.total ?? 0;
  return {
    hostname: m.hostname,
    nodeIp: m.nodeIp,
    machineId: m.machineId,
    cluster,
    role: m.role,
    disks: ds,
    partitions: parts,
    systemDisk,
    systemDiskSizeBytes: sysSize,
    systemDiskUnallocatedBytes: Math.max(0, sysSize - allocated),
    ephemeralSizeBytes: ephSize,
    ephemeralUsedBytes: used,
    ephemeralUsedPercent: ephSize > 0
      ? Math.round((used / ephSize) * 1000) / 10
      : 0,
    ephemeralLibBytes: usage?.lib ?? 0,
    ephemeralLogBytes: usage?.log ?? 0,
    userVolumes: parts.filter((p) => p.label.startsWith("u-")).map((p) =>
      p.label.slice(2)
    ),
    timestamp: now,
  };
}

function redact(text: string, secret: string): string {
  return secret ? text.split(secret).join("[REDACTED]") : text;
}

async function run(
  argv: string[],
  env: Record<string, string>,
  secret: string,
  signal?: AbortSignal,
): Promise<string> {
  const r = await exec(argv, env, signal);
  if (r.code !== 0) {
    throw new Error(
      `${argv[0]} ${argv[1]} failed (exit ${r.code}): ${
        redact((r.stderr || r.stdout).trim(), secret)
      }`,
    );
  }
  return r.stdout;
}

export const extension = {
  type: "@mccormick/omni/inventory",
  resources: {
    volumeLayout: {
      description:
        "Disks, partitions by label, unallocated space and EPHEMERAL usage of one Talos machine, as talosctl reports them through Omni.",
      schema: VolumeLayoutSchema,
      lifetime: "30d" as const,
      garbageCollection: 20,
    },
  },
  methods: [{
    volumes: {
      description:
        "For every machine in one cluster: disks, partitions (STATE, EPHEMERAL, u-<name>, ...), unallocated bytes on the system disk, and /var usage. One volumeLayout resource per node, one execution. Read-only.",
      arguments: VolumesArgsSchema,
      execute: async (
        args: VolumesArgs,
        context: {
          globalArgs: GlobalArgs;
          signal: AbortSignal;
          logger: { info(msg: string, props?: Record<string, unknown>): void };
          writeResource: (
            specName: string,
            name: string,
            data: Record<string, unknown>,
          ) => Promise<{ name: string }>;
        },
      ) => {
        const g = context.globalArgs;
        if (!g.serviceAccountKey) {
          throw new Error("serviceAccountKey is required to query Omni");
        }
        const env = {
          OMNI_ENDPOINT: g.endpoint,
          OMNI_SERVICE_ACCOUNT_KEY: g.serviceAccountKey,
        };
        const omnictl = g.omnictlPath ?? "omnictl";
        const insecure = g.insecureSkipTlsVerify
          ? ["--insecure-skip-tls-verify"]
          : [];
        const key = g.serviceAccountKey;

        const ids = parseConcatJson(
          await run(
            [
              omnictl,
              "get",
              "clustermachineidentity",
              "-o",
              "json",
              ...insecure,
            ],
            env,
            key,
            context.signal,
          ),
        );
        const nodes = members(ids, args.cluster);
        if (nodes.length === 0) {
          throw new Error(
            `cluster ${args.cluster} has no machines with node IPs in Omni`,
          );
        }
        context.logger.info(
          "Querying {count} nodes of {cluster} through Omni",
          {
            count: nodes.length,
            cluster: args.cluster,
          },
        );

        const cfg = await Deno.makeTempFile({ prefix: "omni-talosconfig-" });
        try {
          await run(
            [
              omnictl,
              "talosconfig",
              "-c",
              args.cluster,
              "--merge=false",
              "--force",
              cfg,
              ...insecure,
            ],
            env,
            key,
            context.signal,
          );
          const ips = nodes.map((n) => n.nodeIp).join(",");
          const t = [args.talosctlPath, "--talosconfig", cfg, "-n", ips];
          const [disks, vols, usageText] = await Promise.all([
            run([...t, "get", "disks", "-o", "json"], env, key, context.signal),
            run(
              [...t, "get", "discoveredvolumes", "-o", "json"],
              env,
              key,
              context.signal,
            ),
            run([...t, "usage", "-d", "1", "/var"], env, key, context.signal),
          ]);
          const byNode = (rs: Record_[], ip: string) =>
            rs.filter((r) => r.node === ip);
          const diskRecs = parseConcatJson(disks);
          const volRecs = parseConcatJson(vols);
          const usage = parseUsage(usageText);
          const now = new Date().toISOString();
          const handles = [];
          for (const n of nodes) {
            const layout = buildLayout(
              n,
              args.cluster,
              byNode(diskRecs, n.nodeIp),
              byNode(volRecs, n.nodeIp),
              usage[n.nodeIp],
              now,
            );
            context.logger.info(
              "{host}: EPHEMERAL {used}% of {size} GiB, {free} MiB unallocated",
              {
                host: n.hostname,
                used: layout.ephemeralUsedPercent,
                size: Math.round(layout.ephemeralSizeBytes / 2 ** 30 * 10) / 10,
                free: Math.round(layout.systemDiskUnallocatedBytes / 2 ** 20),
              },
            );
            handles.push(
              await context.writeResource("volumeLayout", n.hostname, layout),
            );
          }
          return { dataHandles: handles };
        } finally {
          await Deno.remove(cfg).catch(() => {});
        }
      },
    },
  }],
};

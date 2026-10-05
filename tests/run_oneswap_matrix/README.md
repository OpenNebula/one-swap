# OneSwap migration matrix and benchmark utility

This utility runs repeatable OneSwap migration validation and performance benchmarks across source VM/environment, migration method, transfer method, and target storage combinations. Each independent YAML configuration represents one test. The runner invokes OneSwap, records comparable timing/results, and cleans up matching OpenNebula templates and images before the next test.

The current example matrix covers **Hybrid**, **VDDK**, and **Delta**. Delta additionally prepares the source VM for each iteration, waits for VMware Tools, validates the source after conversion, and measures migration downtime.

## Directory structure

```text
run_oneswap_matrix/
├── run_oneswap_matrix.sh
├── oneswap_vm_helper.rb
├── configs/
│   ├── 01-vcenter-hybrid-http-local.yaml.example
│   ├── 02-vcenter-vddk-http-local.yaml.example
│   └── 03-vcenter-delta-http-local.yaml.example
└── oneswap-test-results/
```

The supplied examples represent Hybrid (`01-vcenter-hybrid-http-local.yaml.example`), VDDK (`02-vcenter-vddk-http-local.yaml.example`), and Delta (`03-vcenter-delta-http-local.yaml.example`). Adapt their normal OneSwap settings to your environment before use; they are not portable defaults.

Before running the matrix, copy the required example configuration to a `.yaml` file and adapt it to your environment. Files ending in `.yaml.example` are templates only and are not scanned by the runner.

For example:

```bash
cp ./configs/03-vcenter-delta-http-local.yaml.example \
   ./configs/03-vcenter-delta-http-local.yaml
```

Then edit the copied file with the appropriate VM name, credentials, transfer settings, storage settings, and placement options.

The runner scans only regular files ending in `.yaml` or `.yml` directly inside the selected config directory. Subdirectories are not scanned. Files are sorted by filename using `sort`, so numeric prefixes can control test order:

```text
01-hybrid-nfs-lvm.yaml
02-hybrid-http-lvm.yaml
03-vddk-http-lvm.yaml
04-delta-http-lvm.yaml
```

## Requirements and assumptions

- Bash with `mapfile` support (Bash 4 or later).
- OneSwap CLI and the dependencies required by the selected migration/transfer settings.
- OpenNebula CLI: `onetemplate` and `oneimage`, configured with permission to list, inspect, and delete the test's target objects.
- Standard shell utilities including GNU-compatible `date` (`--iso-8601` and `--date`), `find`, `sort`, `sed`, `awk`, `grep`, `xargs`, `tr`, and `tee`.
- Ruby and OneSwap's Ruby libraries/rbvmomi for Delta source handling.
- A working OneSwap YAML configuration and credentials/permissions for migration. Delta additionally requires vCenter access to inspect VM state, VMware Tools, and snapshots, and to power on the source VM.
- VMware Tools installed and able to reach the readiness conditions described below for Delta.
- A writable results directory.
- Benchmark configs should use `:delete: true` so repeated runs do not accumulate conversion data in `work_dir`.

Run from the utility directory: the runner resolves `./oneswap_vm_helper.rb` relative to the current working directory. The helper loads Ruby libraries from `/usr/lib/one/ruby` and gems from `/usr/share/one/gems`; when `ONE_LOCATION` is set it uses `$ONE_LOCATION/lib/ruby` and `$ONE_LOCATION/share/gems` instead.

Use source VMs suitable for repeated migration tests. Delta powers them on and leaves them powered off after a successful migration. Hybrid/VDDK source preparation and recovery are handled by OneSwap and the operator, rather than by this runner.

## Configuration metadata

Place the following metadata comments at the top of every YAML configuration:

| Field | Meaning |
| --- | --- |
| `TEST_ENV` | Optional human-readable reporting label, such as `Lab` or `Production`. Defaults to the environment derived from the source configuration. |
| `TEST_VM` | Exact VMware source VM name passed to OneSwap. Delta helper lookup requires exactly one matching VM. |
| `TEST_METHOD` | Migration label, typically lowercase `hybrid`, `vddk`, or `delta`. The exact value `delta` enables Delta automation and adds `--delta`. |
| `TEST_TRANSFER` | Reporting label describing the YAML transfer settings, such as `nfs`, `http` or `local`. |
| `TEST_STORAGE` | Reporting label describing target storage, such as `nfs`, `lvm`, or `local`. |

These headers are consumed by the matrix runner independently of the normal OneSwap settings below them. `TEST_VM`, `TEST_METHOD`, `TEST_TRANSFER`, and `TEST_STORAGE` are required and must be nonempty. `TEST_ENV` is optional. The runner takes the first matching comment for each field and permits whitespace around `=`. It does not validate the method label against an allowed list or check that labels agree with the YAML.

`TEST_ENV` is optional reporting metadata. For example, add `# TEST_ENV=Production` to label test names, logs, and CSV rows. When omitted or empty, the reporting label defaults to `vcenter`, derived from the configuration's nonempty `vcenter` setting. Symbol and string YAML keys are accepted. The source configuration is checked independently of the label. `TEST_ENV` never affects VM lookup, source selection, preparation, migration, cleanup, or post-migration validation; these use `TEST_VM` and the normal OneSwap YAML settings. ESXi credentials and `esxi_ip` control access/transfer, not the reporting label.

For Hybrid and VDDK, the runner passes no method flag: configure the actual mode in the OneSwap YAML, for example `:hybrid: true` or the appropriate `:vddk_path`. Transfer and storage labels never configure OneSwap themselves.

A generic Delta configuration skeleton is:

```yaml
# TEST_VM=example-vm
# TEST_ENV=vcenter
# TEST_METHOD=delta
# TEST_TRANSFER=local-http
# TEST_STORAGE=local
---
:vcenter: '<VCENTER_HOST>'
:vuser: '<VCENTER_USER>'
:vpass: '<VCENTER_PASSWORD>'
:datastore: 1
:work_dir: '<WORK_DIR>'
:delete: true
http_transfer: true
http_host: '<ONESWAP_WORKER_HOST>'
http_port: 29869
```

Complete the remaining settings for your installed OneSwap version and target environment. The helper requires `vcenter`, `vuser`, and `vpass`, accepts symbol or string top-level keys, and uses OneSwap's connection options. Keep credentials private.

### Cleanup requirement for benchmark runs

Use `:delete: true` in benchmark/test OneSwap configurations. It makes OneSwap remove its temporary conversion data from `work_dir` after the transfer completes. This setting does not delete the VMware source VM or its source disks.

The matrix runner's own cleanup only removes the resulting OpenNebula templates/images; it does **not** clean OneSwap's conversion working directory. Without `:delete: true`, converted disks/files may accumulate between iterations, consume significant disk space, and affect or fail later benchmark runs.

These are two separate cleanup mechanisms:

```text
OneSwap :delete: true
    → cleans temporary conversion data in work_dir

matrix cleanup
    → deletes generated OpenNebula templates/images
```

## Building a test matrix

One YAML file is one matrix point/test iteration. For example:

```text
2 migration methods × 3 transfer methods × 2 target storage types
= 12 YAML files / test iterations
```

A corresponding filename matrix could be:

```text
01-hybrid-nfs-nfs.yaml
02-hybrid-nfs-lvm.yaml
03-hybrid-http-nfs.yaml
04-hybrid-http-lvm.yaml
05-hybrid-local-nfs.yaml
06-hybrid-local-lvm.yaml

07-vddk-nfs-nfs.yaml
08-vddk-nfs-lvm.yaml
09-vddk-http-nfs.yaml
10-vddk-http-lvm.yaml
11-vddk-local-nfs.yaml
12-vddk-local-lvm.yaml
```

Use only combinations supported by your OneSwap version and environment. Dimensions already shown not to materially affect a particular benchmark can be omitted to reduce the matrix. Keep other settings and source conditions consistent when comparing results.

Multiple tests may use the same source VM if each run's source-state and target-cleanup assumptions hold. Delta prepares the source independently every iteration. The runner does not restore source disk contents between migrations.

## Running

From the utility directory:

```bash
./run_oneswap_matrix.sh ./configs
```

Defaults and overrides:

| Setting | Default | Override |
| --- | --- | --- |
| Config directory | `./configs` | First positional argument |
| OneSwap executable | `oneswap` | `ONESWAP` environment variable |
| Result root | `./oneswap-test-results` | `LOG_ROOT` environment variable |

```bash
ONESWAP=/path/to/oneswap ./run_oneswap_matrix.sh ./configs
LOG_ROOT=/some/path ./run_oneswap_matrix.sh ./configs
```

`ONESWAP` is a single executable name or path, not a command with additional arguments. For long matrices, running in `screen` or `tmux` helps preserve the session.

## Common per-test lifecycle

1. Read and validate the required metadata and resolve the optional environment label.
2. Verify no OpenNebula template/image matching the source VM exists.
3. Perform Delta preparation and start its monitor, if applicable.
4. Run OneSwap and capture command exit status and timing.
5. Process Delta downtime and post-validation, if applicable, then determine `PASS` or `FAIL`.
6. Delete matching templates first and wait for each deletion.
7. Delete matching images and wait for each deletion.
8. Write the result to CSV after successful cleanup.
9. Stop on a failed result; otherwise start the next configuration.

The non-Delta command is:

```bash
oneswap convert '<VM_NAME>' --config-file '<CONFIG_PATH>'
```

Preflight is essential because cleanup identifies objects by searching the complete `onetemplate list --no-header` and `oneimage list --no-header` output for the VM name as a literal substring, then taking the first column as the object ID. It refuses to start when matches already exist or listing fails.

Use distinct VM names, adequate list visibility, and no concurrent creation of matching objects between preflight and cleanup. Matching is not an exact-name or ownership check; cleanup does not track IDs returned by OneSwap. Under these assumptions, the matching objects after conversion belong to the test.

Deletion waits poll every two seconds, with limits of 60 seconds per template and 120 seconds per image. A nonzero `show` exit is treated as deletion completion, so reliable OpenNebula CLI access is assumed throughout cleanup.

## Delta lifecycle

```text
check no existing OpenNebula objects
        ↓
check no VMware snapshots
        ↓
power on source VM and wait for poweredOn
        ↓
wait for VMware Tools:
  toolsStatus == toolsOk
  toolsRunningStatus == guestToolsRunning
        ↓
start powered-off monitor
        ↓
start total migration timer
        ↓
oneswap convert <VM> --delta --config-file <config>
        ↓
first observe poweredOff → record downtime start
        ↓
OneSwap completes → record migration end
        ↓
stop/reap monitor and calculate downtime
        ↓
validate poweredOff and no snapshots remain
        ↓
clean target OpenNebula objects
        ↓
write CSV result
```

Existing VMware snapshots fail preparation before power-on. An already powered-on VM is accepted; other states besides `poweredOff` and `poweredOn` are rejected by `power-on`. Each successful Delta iteration leaves the source powered off, allowing this repeated sequence:

```text
power on → Delta → powered off → cleanup → power on → Delta → ...
```

Source post-validation runs only when conversion and downtime processing have succeeded. On Delta failure, an additional snapshot inspection is attempted. **The utility never automatically removes VMware snapshots.** Any remaining snapshot is left for manual inspection. Target OpenNebula cleanup still runs after conversion/timing/validation failures, and the matrix then stops.

### VMware Tools readiness

`poweredOn` alone does not indicate that VMware Tools can service a graceful shutdown request. To make graceful shutdown validation representative, `wait-tools-ready` polls until the source is `poweredOn` and both guest properties match:

```text
toolsStatus == toolsOk
toolsRunningStatus == guestToolsRunning
```

This check polls approximately once per second and has a 120-second operation timeout, including connection and VM lookup. It checks VMware Tools readiness rather than application health.

## Timing metrics

### Total migration duration

`duration_seconds` measures the interval from immediately before `oneswap convert` starts until that command completes. The runner records completion inside the command pipeline before `tee` finishes draining output. VM preparation, Tools readiness, header logging, monitor termination, Delta post-validation, and OpenNebula cleanup are excluded.

Timestamps use the runner host's wall clock in whole epoch seconds; `duration` is the corresponding `HH:MM:SS` representation. Keep the host clock stable during benchmarks.

### Delta downtime

`downtime_seconds` is the interval from the monitor's first observation of the VMware source VM in `poweredOff` state until OneSwap command completion. `downtime` formats it as `HH:MM:SS`.

This is **migration downtime**, not full application/service downtime. It excludes deploying or booting the resulting OpenNebula VM and waiting for application health.

The monitor keeps one vCenter connection open and polls at approximately one-second intervals, giving roughly one-second observation resolution plus API latency. It writes the observed epoch timestamp immediately to a file. It is launched before conversion, but the runner does not wait for an explicit monitor-ready handshake. A valid timestamp must contain only digits and be no later than command completion.

The monitor's default operation timeout is 3,600 seconds, including connection and lookup. The runner uses this default; only direct helper calls can change it with `--timeout`. Monitor timeout/error does not terminate OneSwap. After conversion, the runner terminates/reaps any outstanding monitor and marks otherwise successful conversion as failed if the downtime timestamp is missing or invalid. It does not extend the migration endpoint by waiting for a later power-off observation. There is no runner-imposed OneSwap command timeout.

Hybrid/VDDK rows leave both downtime fields empty. Delta rows contain downtime when successfully captured, including on a failed conversion if a valid timestamp exists.

## VMware helper

`oneswap_vm_helper.rb` reuses OneSwap's `OneSwapHelper` connection handling and Ruby/rbvmomi stack; it introduces no `govc` dependency.

```bash
ruby ./oneswap_vm_helper.rb COMMAND VM_NAME --config-file PATH
```

Exactly one command and one VM name are required. Quote names containing spaces. `--config-file` defaults to `/etc/one/oneswap.yaml`; the runner always passes the current test configuration. VM lookup requires a unique exact name.

| Command | Purpose |
| --- | --- |
| `state` | Print `<VM_NAME>: <powerState>`. |
| `power-on` | Power on a powered-off VM, or accept one already on, then wait for `poweredOn`. |
| `wait-tools-ready` | Wait for `poweredOn`, `toolsOk`, and `guestToolsRunning`. |
| `wait-powered-off` | Wait for the first observation of `poweredOff` and write an epoch timestamp. |
| `snapshots` | Print snapshot names and fail if snapshots exist; never delete them. |

For `wait-powered-off`, `--timestamp-file PATH` is required. Its parent directory must exist and be writable. `--timeout SECONDS` accepts a positive integer and changes only this command's operation timeout (default 3,600 seconds). All other commands retain their 120-second operation timeout even if `--timeout` is supplied. Connection closure is attempted with a separate ten-second limit.

```bash
ruby ./oneswap_vm_helper.rb snapshots 'source-vm' --config-file ./configs/03-vcenter-delta-http-local.yaml
```

Successful commands exit `0`; detected snapshots exit `2`. Configuration, connection, lookup, timeout, and other handled command errors exit `1` with a diagnostic. A connection-close error is reported as a warning.

## Results and logs

```text
oneswap-test-results/
└── YYYYMMDD_HHMMSS/
    ├── summary.log
    ├── timings.csv
    ├── 1_<test-name>.log
    ├── 1_<test-name>.migration_end
    ├── 2_<test-name>.log
    ├── 2_<test-name>.migration_end
    ├── 3_<delta-test-name>.log
    ├── 3_<delta-test-name>.migration_end
    ├── 3_<delta-test-name>.downtime_start
    └── ...
```

Run directory names and displayed times use the runner host's local timezone. Avoid simultaneous starts with the same result root in the same second, since run IDs have second resolution.

- `summary.log`: run-level progress and conversion results.
- `<number>_<test-name>.log`: OneSwap output and preparation, validation, monitor, and cleanup output for that iteration. The state lookup in Delta post-validation suppresses stderr.
- `timings.csv`: machine-readable results for comparison and analysis.
- `<number>_<test-name>.migration_end`: command completion epoch, produced for every executed conversion.
- `<number>_<test-name>.downtime_start`: first observed powered-off epoch, produced only for Delta when captured.

The test name combines VM, environment, method, transfer, and storage labels; it is lowercased and sanitized for filenames. Auxiliary timing files remain in the results directory.

### CSV schema

The exact 16-column header is:

```csv
test_name,vm,environment,migration_method,transfer_method,target_storage,config,status,exit_code,duration_seconds,duration,downtime_seconds,downtime,start_time,end_time,log
```

| Columns | Contents |
| --- | --- |
| `test_name` | Sanitized combined metadata name. |
| `vm`, `environment`, `migration_method`, `transfer_method`, `target_storage` | Test metadata values. |
| `config` | YAML filename without its directory. |
| `status` | `PASS` or `FAIL` after conversion/timing/post-validation; `PREPARATION_FAILED` when Delta preparation aborts before migration. |
| `exit_code` | OneSwap command code, or runner-assigned validation/timing code. |
| `duration_seconds`, `duration` | Total migration seconds and `HH:MM:SS`. |
| `downtime_seconds`, `downtime` | Delta downtime seconds and `HH:MM:SS`; empty for non-Delta tests or missing measurements. |
| `start_time`, `end_time` | ISO 8601 timestamps with host timezone offset. |
| `log` | Per-test log path. |

The writer does not quote or escape CSV values. Avoid commas, quotes, and newlines in metadata, config filenames, and result paths used for CSV analysis.

## Failure behavior

| Condition | Current behavior |
| --- | --- |
| Missing directory/executable, no configs, or missing metadata | Stop with runner exit `1`. |
| Pre-existing matching OpenNebula objects or inability to list them | Refuse the iteration; runner exit `2`, without source preparation or cleanup. |
| Existing VMware snapshots, power-on error, or Tools readiness timeout | Stop during Delta preparation with runner exit `2`; no conversion. Record a `PREPARATION_FAILED` CSV row with empty migration timing fields. |
| OneSwap conversion failure | Preserve its command code as the result, attempt Delta snapshot inspection if applicable, perform target cleanup, write `FAIL` after successful cleanup, then stop with runner exit `3`. |
| Missing/invalid Delta downtime timestamp | Assign result code `5` if conversion otherwise succeeded; preserve a prior conversion failure code. |
| Delta source post-validation failure | Assign result code `4`; attempt snapshot inspection, clean targets, record failure, and stop. |
| Delta snapshot inspection after failure also fails | Log the error and leave snapshots untouched; preserve the existing failure code and continue target cleanup before stopping. |
| Target cleanup/listing/deletion/wait failure | Stop with runner exit `2` before writing that iteration's CSV row. Conversion results remain in logs. |

Runner process exit codes and CSV result codes have different meanings: successful completion of the entire matrix exits `0`; an iteration's failed result normally stops the runner with `3` after successful cleanup.

Preflight and cleanup failures may have no CSV row. Delta preparation failures have a `PREPARATION_FAILED` row with no migration timing. Consult logs alongside CSV when a matrix stops early. Inspect remaining source snapshots manually before retrying. Normal post-conversion handling stops the monitor, but the runner has no signal/interrupt trap to guarantee cleanup after external interruption.

Run isolated VMware preparation regression checks with `python3 -m unittest -v test_preparation.py`. These use mocked VMware and OpenNebula dependencies and do not contact a source VM.

# Redmi K50 (rubens) / HyperOS 2 research build

Target: Redmi K50, `OS2.0.10.0.ULNCNXM`, Android 14, KernelSU.

## Adaptation

- Detect `/vendor/bin/mi_thermald` via `init.svc.mi_thermald`, not `which`.
- Reuse the upstream AES-encrypted `t_map` and 1–5 thermal profiles without rewriting the vendor partition.
- Disable direct charging-current and bypass writes on `rubens`. The phone's `battery/charge_control_limit` is not a verified microampere interface.
- Track and back up only `thermal-normal.conf` and `thermal-map.conf` under the cloud configuration directory, then restore only those files.
- Keep the module disabled by default; manually enable from WebUI after reboot.

## Installation / testing

Package from the **research** branch with `module.prop` at the ZIP root (not a GitHub-generated wrapper directory). Install in KernelSU and reboot.

1. Check `/data/adb/modules/HyperThermal/log.log` for service detection.
2. Confirm `config/runtime.json` shows `mi_thermald` and an empty `charge_node`.
3. Confirm `battery/charge_control_limit` remains managed by the stock system.
4. Enable the module in WebUI, choose a non-unlimited thermal level, then confirm the two overlay files are written and the thermal service restarts.
5. Disable in WebUI and verify only module-managed overlay files are restored/removed.

No on-device test has been performed in this branch yet. The upstream thermal profiles have not been validated against the K50's temperature behavior. Use the stock/default mode for the first boot. Changes to charging power are **not** guaranteed because USB-PD/private fast-charge negotiation is outside this patch.

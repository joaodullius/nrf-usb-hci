# ubx_evknorab12 (u-blox EVK-NORA-B12, NORA-B12 series, nRF5340)

Board definition from u-blox:
https://github.com/u-blox/u-blox-sho-OpenCPU/tree/master/zephyr/boards/u-blox/ubx_evknorab12
(last upstream change 2026-02-05, "Various updates to the EVK-NORA-B10 and EVK-NORA-B12").
License: Apache-2.0 (see file headers).

## Local modifications (this project)

- `ubx_evknorab12_nrf5340_cpuapp_partition.dtsi` (new): application core flash
  layout with every MCUboot slot in internal flash, because the NORA-B12 module
  has no external flash. Same layout as the Thingy:53 test setup:
  mcuboot 64 KB | slot0 352 KB | slot1 352 KB | slot3 256 KB (net core update).
- `ubx_evknorab12_nrf5340_cpuapp.dts`: includes the file above instead of
  `nordic/nrf5340_cpuapp_partition.dtsi`.
- `ubx_evknorab12_nrf5340_cpunet.dts`: network core partitions converted from
  `fixed-partitions` to the `zephyr,mapped-partition` format used by NCS v3.4
  (same addresses).

Not changed: the MX25R64 on the EVK carrier stays in the devicetree but has no
partitions; the `cpuapp/ns` (TF-M) variant keeps the upstream layout and is not
used by this project. The network core defconfig enables MPSL and the FEM; the
project turns them off only for the b0n bootloader (`sysbuild/b0n.conf`).

# keys/

Private signing keys live here and are **not** committed (`keys/*.pem` is in
`.gitignore`).

- `b0n_dev_private.pem`: network core (b0n / NSIB) signing key, ECDSA P-256,
  PKCS#8. Referenced by `SB_CONFIG_SECURE_BOOT_SIGNING_KEY_FILE` in
  `sysbuild.conf`. Generate one before the first build:

  ```bash
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out keys/b0n_dev_private.pem
  ```

  Keep it: the hash of its public key is provisioned into the device when it is
  flashed with the J-Link, and only images signed with the same key are accepted
  by later network core updates.

# nrf-usb-hci — Controlador Bluetooth USB com DFU pela USB (nRF5340)

Firmware para nRF5340 que expõe o controlador Bluetooth LE ao computador pela USB
(classe Bluetooth HCI) e, na mesma USB, uma porta serial CDC ACM com MCUmgr (SMP)
para atualizar o app core e o network core sem programador.

- **Alvo:** módulos nRF5340 **sem flash externa**. Todos os slots de atualização
  ficam na flash interna.
- **Placas suportadas:** `thingy53/nrf5340/cpuapp` (bancada, sem usar a flash
  externa dela) e `ubx_evknorab12/nrf5340/cpuapp` (EVK-NORA-B12, placa da u-blox
  incluída em `boards/u-blox/`). As duas usam o mesmo layout de memória.
- **SDK:** nRF Connect SDK v3.4.1. Base: sample `zephyr/samples/bluetooth/hci_usb`.

## Arquitetura

```
 Host                                         nRF5340
 ────                                         ─────────────────────────────────────────
 Pilha Bluetooth ◄── USB função 1: BT HCI ──► cpuapp: classe USBD BT HCI ─┐
 (BTHUSB/btusb)      interfaces 0 e 1                                     │ IPC (HCI)
                                                                          ▼
 nrfutil/smpmgr ◄── USB função 2: CDC ACM ─► cpuapp: MCUmgr SMP     cpunet: hci_ipc
 (COMx/ttyACMx)      interfaces 2 e 3            │                   (controlador BLE)
                                                 ▼
                                    flash interna (slots de atualização)
```

| Imagem   | Núcleo  | Função                                                        |
|----------|---------|---------------------------------------------------------------|
| mcuboot  | cpuapp  | Bootloader. Aplica atualizações das imagens 0 (app) e 1 (net). |
| app      | cpuapp  | USB (BT HCI + CDC ACM), MCUmgr, LED de keep-alive.            |
| b0n      | cpunet  | Bootloader imutável do network core (NSIB).                   |
| hci_ipc  | cpunet  | Controlador Bluetooth LE, fala HCI com o app core por IPC.    |

O LED verde pisca a 1 Hz enquanto o app roda.

A USB segue o VBUS: o app liga o dispositivo quando o VBUS aparece e desliga quando
some (`src/main.c`). Sem isso, uma queda de VBUS depois do boot (troca de cabo, host
que corta a energia da porta) deixava o pull-up do D+ desligado e o dispositivo sumia
até o próximo reset.

## Como os dois protocolos coexistem na mesma USB

O dispositivo é **USB composto**. Cada protocolo é uma função separada, com
interfaces e endpoints próprios, e os dados de um nunca passam pelo canal do outro.

- Cada pacote USB leva o número do endpoint de destino, e cada endpoint pertence a
  uma só função.
- HCI: `0x81` interrupt IN (eventos), `0x82`/`0x02` bulk (ACL), `0x83`/`0x03`
  isócronos. A CDC ACM recebe os próximos endpoints livres (um interrupt IN e um par
  bulk). Uso total: 4 de 7 IN, 2 de 7 OUT e o único par ISO, que fica com o HCI.
- O host sondeia os endpoints em quadros de 1 ms. Interrupt e ISO têm banda
  reservada; o bulk do HCI e o da CDC dividem o restante dos 12 Mbit/s.
- O descritor usa a classe "composto com IAD" (0xEF/0x02/0x01), ajustada em
  `src/sample_usbd_init.c` quando a CDC ACM está habilitada.

Interações reais:

- **Reset para aplicar a atualização:** o dispositivo inteiro desconecta e volta.
  O controlador Bluetooth some do host e as conexões BLE caem.
- **Durante o upload:** o app core grava a flash enquanto atende o HCI; o rádio no
  network core não é afetado.
- **Console:** a porta CDC carrega só frames SMP (`CONFIG_UART_CONSOLE=n`).
- **Windows:** só um adaptador Bluetooth fica ativo por vez (evento BTHUSB 6,
  código 31). Isso afeta só a função HCI; a porta COM continua funcionando.
- **Linux:** o ModemManager pode sondar a ttyACM. Para evitar:

  ```
  # /etc/udev/rules.d/99-nrf-usb-hci.rules
  ATTRS{idVendor}=="2fe3", ATTRS{idProduct}=="000b", ENV{ID_MM_DEVICE_IGNORE}="1"
  ```

## Layout de flash

Sem Partition Manager: as partições estão em devicetree. Tudo fica na flash interna.

| Memória            | Partição          | Endereço  | Tamanho | Uso                               |
|--------------------|-------------------|-----------|---------|-----------------------------------|
| Flash app (1 MB)   | `boot_partition`  | 0x000000  | 64 KB   | MCUboot (usa ~53 KB)              |
|                    | `slot0_partition` | 0x010000  | 352 KB  | Imagem 0 ativa (app, ~84 KB)      |
|                    | `slot1_partition` | 0x068000  | 352 KB  | Imagem 0 nova                     |
|                    | `slot3_partition` | 0x0C0000  | 256 KB  | Imagem 1 nova (network core)      |
| RAM (flash sim)    | `slot2_partition` | —         | 256 KB  | Ponte PCD para o network core     |
| Flash net (256 KB) | `b0n_partition`   | 0x000000  | 0x8580  | b0n                               |
|                    | provision         | 0x008580  | 0x280   | Hash da chave do b0n              |
|                    | `s0_partition`    | 0x008800  | 222 KB  | hci_ipc (~131 KB)                 |

Regras que o layout precisa respeitar:

- **`slot3` tem que ter o mesmo tamanho do `slot2` (256 KB).** O MCUboot só aceita
  slots com o mesmo número de setores. Se forem diferentes, ele registra
  `Cannot upgrade: slots have non-compatible sectors` e ignora a atualização do
  network core sem erro visível para o host.
- O app core não acessa a flash do network core. Na atualização, o MCUboot copia a
  imagem do `slot3` para a RAM e o b0n do network core grava a partir dali (PCD).

Arquivos:

- `boards/nrf5340_internal_flash_partitions.dtsi`: o layout do app core, usado pelo
  overlay da Thingy:53 e pelo MCUboot.
- `boards/thingy53_nrf5340_cpuapp.overlay`: aplica o layout na Thingy:53. Nenhuma
  partição na MX25R64.
- `boards/u-blox/ubx_evknorab12/`: placa da EVK-NORA-B12, com o layout já na própria
  definição (`ubx_evknorab12_nrf5340_cpuapp_partition.dtsi`). As mudanças em relação
  ao original da u-blox estão em `SOURCE.md` na mesma pasta.
- `sysbuild/mcuboot.overlay`, `sysbuild/mcuboot.conf`: layout e opções do MCUboot.
- `sysbuild/b0n.overlay`, `sysbuild/hci_ipc.overlay`: layout do network core. Os
  overlays removem as partições padrão pelo nome do nó, por isso valem para as duas
  placas.
- `sysbuild/b0n.conf`: desliga MPSL e FEM no b0n (a placa da EVK-NORA-B12 liga os
  dois no network core; o controlador Bluetooth mantém).
- `sysbuild.conf`: netcore `hci_ipc`, MCUboot overwrite-only com duas imagens, b0n,
  sem Partition Manager, sem flash externa, chave do b0n fixa (teste do MCUboot).

### Placas sem cristal de 32 kHz

As duas placas suportadas usam o cristal de 32,768 kHz (LFXO). Em hardware sem
esse cristal, a fonte do relógio de baixa frequência precisa ser o oscilador RC
interno em **todas** as imagens: app, MCUboot, b0n e hci_ipc. O lugar natural é a
definição da placa (`*_cpuapp_defconfig` e `*_cpunet_defconfig`):

```
CONFIG_CLOCK_CONTROL_NRF_K32SRC_RC=y
```

### Network core

O app libera o network core do reset no boot (`CONFIG_SOC_NRF53_CPUNET_ENABLE=y`
no `prj.conf`). A Thingy:53 já faz isso por padrão, mas a EVK-NORA-B12 não: sem a
opção, o app, a USB e o MCUmgr funcionam, e o controlador Bluetooth nunca sobe.

## Chaves de assinatura

As duas chaves de desenvolvimento são as de teste que vêm com o MCUboot no NCS.
Elas são públicas, fixas e iguais em qualquer máquina, então um clone compila sem
nenhum passo extra e as atualizações continuam válidas entre builds.

| Bootloader            | Chave                                                  | Opção                                     |
|-----------------------|--------------------------------------------------------|-------------------------------------------|
| MCUboot (app core)    | `root-rsa-2048.pem` (padrão do MCUboot)                | `SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`       |
| b0n (network core)    | `${ZEPHYR_MCUBOOT_MODULE_DIR}/root-ec-p256-pkcs8.pem`  | `SB_CONFIG_SECURE_BOOT_SIGNING_KEY_FILE`  |

- O hash da chave do b0n é gravado no provisionamento do network core na gravação
  pela J-Link. Atualizações do network core só são aceitas se assinadas com a mesma
  chave; trocar a chave exige uma nova gravação completa pela J-Link.
- Não deixe o b0n sem chave configurada: nesse caso o NCS gera uma chave aleatória
  dentro de `build/`, e um build limpo invalida as atualizações.
- **Produção:** chaves públicas não protegem nada. Gere e guarde chaves próprias
  para os dois bootloaders (fora do repositório; `*.pem` está no `.gitignore`) e
  troque o VID/PID de testes do Zephyr (`CONFIG_SAMPLE_USBD_VID`/`PID`).

## Build

Nos comandos abaixo, `<ncs>` é a instalação do NCS (por exemplo `C:\ncs\v3.4.1`)
e `<proj>` é a pasta deste projeto, ambos com caminho absoluto.

Thingy:53:

```powershell
nrfutil sdk-manager toolchain launch --ncs-version v3.4.1 --chdir <ncs> -- `
  west build -b thingy53/nrf5340/cpuapp --sysbuild -d <proj>/build <proj>
```

EVK-NORA-B12. A placa fica no próprio projeto, então é preciso passar `BOARD_ROOT`
(entre aspas no PowerShell, por causa do `:` do caminho no Windows):

```powershell
nrfutil sdk-manager toolchain launch --ncs-version v3.4.1 --chdir <ncs> -- `
  west build -b ubx_evknorab12/nrf5340/cpuapp --sysbuild -d <proj>/build_nora `
  <proj> -- '-DBOARD_ROOT=<proj>'
```

Versão de release (sempre maior que a instalada):

```powershell
... west build ... -- '-DCONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION="1.0.1"' -Dhci_ipc_CONFIG_FW_INFO_FIRMWARE_VERSION=2
```

Artefatos em `build/`:

| Arquivo                                   | Uso                                |
|-------------------------------------------|------------------------------------|
| `nrf-usb-hci/zephyr/zephyr.signed.bin`    | Atualização da imagem 0 (app core) |
| `signed_by_mcuboot_and_b0_hci_ipc.bin`    | Atualização da imagem 1 (net core) |
| `dfu_application.zip`                     | Pacote com as duas imagens         |

## Gravação inicial (J-Link)

Necessária na primeira vez e sempre que o MCUboot, o b0n ou o layout mudarem.

```powershell
nrfutil device list    # identifique o J-Link cujo alvo é nRF5340
nrfutil sdk-manager toolchain launch --ncs-version v3.4.1 --chdir <ncs> -- `
  west flash --no-rebuild -d <proj>/build --dev-id <serial-do-jlink>
```

## Atualização pela USB (MCUmgr)

Regras:

- Envie cada imagem com o número explícito: `0` para o app core, `1` para o network core. Não use o
  envio do `dfu_application.zip` pelo `nrfutil mcu-manager` 0.12: ele gravou a imagem
  do app no slot do network core.
- Marque **primeiro o network core, depois o app** (problema conhecido NCSDK-34106:
  se o app for ativado antes, o MCUboot pula o network core).
- Use o hash do arquivo exato que foi enviado (`nrfutil mcu-manager image-hash`).
- O MCUboot está em overwrite-only: `image-test` e `image-confirm` têm o mesmo efeito.

Preparação (vale para os três procedimentos). No Windows, a porta é a
"Dispositivo Serial USB" com VID `2FE3`/PID `000B`. No Linux, é a `ttyACM` do mesmo
dispositivo (`/dev/serial/by-id/*Zephyr*`).

```powershell
$port = "COMxx"
$net  = "build\signed_by_mcuboot_and_b0_hci_ipc.bin"
$app  = "build\nrf-usb-hci\zephyr\zephyr.signed.bin"
$hnet = (nrfutil mcu-manager image-hash --firmware $net | Select-Object -First 1).Trim()
$happ = (nrfutil mcu-manager image-hash --firmware $app | Select-Object -First 1).Trim()
```

```bash
# Linux, com smpmgr (pip install smpmgr)
PORT=/dev/serial/by-id/usb-Zephyr_Project_Zephyr_USBD_BT_HCI_*
NET=signed_by_mcuboot_and_b0_hci_ipc.bin
APP=zephyr.signed.bin
hash() { python3 -c 'import sys;from smpclient.mcuboot import ImageInfo;print(ImageInfo.load_file(sys.argv[1]).get_tlv(0x10).value.hex())' "$1"; }
```

### Atualizar só o app core (imagem 0)

Requisito: `CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION` maior que a versão instalada.

1. Enviar a imagem para o slot de atualização do app:

   ```powershell
   nrfutil mcu-manager serial image-upload --serial-port $port --image-number 0 --firmware $app
   ```
2. Marcar para aplicar no próximo boot:

   ```powershell
   nrfutil mcu-manager serial image-test --serial-port $port --hash $happ
   ```
3. Reiniciar. O MCUboot copia o slot1 para o slot0 e a USB volta em ~9 s:

   ```powershell
   nrfutil mcu-manager serial reset --serial-port $port
   ```
4. Verificar: a imagem 0 no slot 0 deve mostrar a versão nova, `active` e `confirmed`.

   ```powershell
   nrfutil mcu-manager serial image-list --serial-port $port
   ```

Linux:

```bash
smpmgr --port $PORT image upload "$APP" --slot 0
smpmgr --port $PORT image state-write "$(hash "$APP")"
smpmgr --port $PORT os reset
smpmgr --port $PORT image state-read      # depois que a ttyACM voltar
```

### Atualizar só o network core (imagem 1)

Requisito: `-Dhci_ipc_CONFIG_FW_INFO_FIRMWARE_VERSION` maior que a versão instalada.
O b0n recusa versão igual ou menor.

1. Enviar a imagem para o slot do network core (`slot3`):

   ```powershell
   nrfutil mcu-manager serial image-upload --serial-port $port --image-number 1 --firmware $net
   ```
2. Marcar para aplicar no próximo boot:

   ```powershell
   nrfutil mcu-manager serial image-test --serial-port $port --hash $hnet
   ```
3. Reiniciar. O MCUboot copia a imagem para a RAM compartilhada e o b0n grava o
   network core. A USB volta em ~12 s. **Não desligue a placa nesse intervalo.**

   ```powershell
   nrfutil mcu-manager serial reset --serial-port $port
   ```
4. Verificar: a imagem 1 some da lista (slot consumido). A versão gravada no network
   core só é visível pela J-Link, no campo de versão do `fw_info`:

   ```powershell
   nrfutil mcu-manager serial image-list --serial-port $port
   nrfutil device read --serial-number <jlink> --core Network --address 0x01008A14 --bytes 4 --width 32
   ```

Linux:

```bash
smpmgr --port $PORT image upload "$NET" --slot 1
smpmgr --port $PORT image state-write "$(hash "$NET")"
smpmgr --port $PORT os reset
smpmgr --port $PORT image state-read      # a imagem 1 não deve mais aparecer
```

### Atualizar os dois núcleos juntos

Use quando a interface entre os núcleos mudar. A ordem importa: **network core
primeiro, app depois** (NCSDK-34106).

1. Enviar e marcar o network core:

   ```powershell
   nrfutil mcu-manager serial image-upload --serial-port $port --image-number 1 --firmware $net
   nrfutil mcu-manager serial image-test   --serial-port $port --hash $hnet
   ```
2. Enviar e marcar o app:

   ```powershell
   nrfutil mcu-manager serial image-upload --serial-port $port --image-number 0 --firmware $app
   nrfutil mcu-manager serial image-test   --serial-port $port --hash $happ
   ```
3. Conferir que as duas aparecem como `pending` e reiniciar. A USB volta em ~16 s.

   ```powershell
   nrfutil mcu-manager serial image-list --serial-port $port
   nrfutil mcu-manager serial reset      --serial-port $port
   ```
4. Verificar o app com `image-list` e o network core pela J-Link, como acima.

Linux: `tools/linux_test.sh update <dir>` faz esses passos na ordem correta.
`<dir>` deve conter `app.signed.bin` e `net.signed.bin`.

### Resultados na Thingy:53 (sem flash externa, NCS v3.4.1, 2026-09-30)

| Teste                    | Antes           | Depois          | Upload        | Volta da USB |
|--------------------------|-----------------|-----------------|---------------|--------------|
| Só network core          | fw 1            | fw 2            | 7,4 s         | 12 s         |
| Só app core              | 0.0.0           | 1.0.1           | 4,7 s         | 8 s          |
| Os dois juntos           | 1.0.1 / fw 2    | 1.0.2 / fw 3    | 7,2 s + 4,7 s | 15 s         |

Depois da troca da chave do b0n para a chave de teste do MCUboot, o teste dos dois
núcleos juntos foi repetido (0.0.0 / fw 1 para 1.0.1 / fw 2) com o mesmo resultado.

Depois de cada teste a placa voltou a enumerar as duas funções USB (Bluetooth e a
porta serial). A EVK-NORA-B12 compila com o mesmo layout, mas não foi testada em
hardware.

### Recuperação serial

Se o app não subir, o MCUboot tem recuperação pela USB: segure o **botão 2** da
Thingy:53 durante o reset. Limitações conhecidas do NCS para o network core nesse
modo: NCSDK-18357 e NCSDK-11308 (espere 30 s antes de desligar). Prefira a
atualização pelo app.

## Pendências

- **Função Bluetooth HCI sem teste com pilha de host.** A função enumera no PC, mas
  a documentação do sample prevê um host como o BlueZ (Linux). No Windows, com o
  adaptador interno desligado, o driver carrega e termina com código 43, provavelmente
  porque o controlador é só BLE. Com o adaptador interno ligado, o código é 31
  (um adaptador por vez).
- **Host Linux com porta USB-C dual-role (Arduino UNO Q):** a enumeração falhou
  com `error -71` em toda tentativa, ligando a placa por um adaptador em Y com
  alimentação. A porta continuou reportando papel de dispositivo. O mesmo firmware
  enumera normalmente num PC. Próximo passo: testar com um hub USB 2.0 entre o
  adaptador e a placa.
- **EVK-NORA-B12:** compilado, sem teste em hardware.
- **Produção:** chaves próprias para MCUboot e b0n (hoje são as chaves públicas de
  teste) e VID/PID próprios.

## Configuração (`prj.conf`)

| Bloco               | Opções principais                                                    |
|---------------------|----------------------------------------------------------------------|
| Bluetooth HCI USB   | `BT_HCI_RAW`, `USBD_BT_HCI`                                          |
| USB                 | `USB_DEVICE_STACK_NEXT`, `USBD_CDC_ACM_CLASS`, PID `0x000B`          |
| Porta CDC só p/ SMP | `SERIAL`, `CONSOLE=y`, `UART_CONSOLE=n`, `UART_MCUMGR`               |
| MCUmgr              | `MCUMGR`, `MCUMGR_TRANSPORT_UART`, `MCUMGR_GRP_IMG`, `MCUMGR_GRP_OS` |
| Keep-alive          | `GPIO`                                                               |

## Origem dos arquivos

- `src/main.c`: `hci_usb/src/main.c` com LED de keep-alive e controle por VBUS.
- `src/sample_usbd_init.c`, `src/sample_usbd.h`, `Kconfig.sample_usbd`: cópia de
  `zephyr/samples/subsys/usb/common`, para compilar fora da árvore do Zephyr.
- `tools/linux_test.sh`: teste de host em Linux (USB, BLE, SMP, atualização).
- `README.upstream.rst`: README original do sample.

## Licença

Apache-2.0 (`LICENSE`). Os arquivos derivados do Zephyr (`src/`, `Kconfig.sample_usbd`,
`README.upstream.rst`) e a placa da u-blox (`boards/u-blox/`) mantêm os cabeçalhos
e a licença Apache-2.0 originais.

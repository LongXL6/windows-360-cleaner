# Detection catalog

Read this reference when reviewing a finding, adding a detector, or deciding whether a path is safe to remove.

## Confidence levels

- `Confirmed`: exact product record, exact known path plus product fingerprint, or persistence action whose executable is under a confirmed path.
- `ReviewOnly`: name match, offline-system path, unsigned component, system driver, or ambiguous toolbox component. Never automatically remove it.

## Confirmed product families

Installed-product names and publishers commonly include:

- 360安全卫士 / 360 Total Security
- 360杀毒
- 360安全浏览器 / 360se
- 360极速浏览器 / 360Chrome
- 360驱动大师
- 360软件管家 / SoftMgr
- 360压缩、360游戏大厅、360桌面助手、360壁纸、360画报
- 多绘屏保 / duohuipingbao
- Publishers such as `360.cn`, `360安全中心`, `Qihoo`, `Qihu`, or `奇虎`

Prefer a working vendor uninstaller. Remove an orphan uninstall record only after its install location and uninstall command have been inspected.

## Exact current-user paths

These are strong candidates. Payload paths should contain the expected marker shown in parentheses where specified.

- `%LOCALAPPDATA%\dhpingbao` (`duohuipingbao.exe` or `huabaosetup.exe`)
- `%TEMP%\duohuipingbao` (`360hb_tmp`, `duohuipingbao.exe`, or `huabaosetup.exe`)
- `%TEMP%\huabao_tmp` (`huabaosetup.exe`)
- `%APPDATA%\360se6`
- `%APPDATA%\360browser`
- `%APPDATA%\360Safe`
- `%APPDATA%\360GameAssistant`
- `%APPDATA%\360huabao`
- `%APPDATA%\360DrvMgrScrSaver`
- `%LOCALAPPDATA%\360Chrome`
- `%APPDATA%\greencore` (`360greencore.exe`)
- `%APPDATA%\GreenCore7z` (`360greencore.exe` or paired confirmed SoftMgr evidence)
- `%APPDATA%\SoftMgr*` (`softmgrsvr.exe`, `SoftMgrUpdate.exe`, or 360 DLL markers)

Known temporary packages include `%TEMP%\360greencore.cab`, `%TEMP%\360se*.cab`, `%TEMP%\360gameassistantYyb`, and `%TEMP%\360UnPackTmp64`.

## Exact machine paths

- `%ProgramFiles%\360`
- `%ProgramFiles(x86)%\360`
- `%ProgramData%\360`
- `%ProgramData%\360safe`
- `%ProgramFiles%\softmgr` only when product metadata or marker files identify 360/SoftMgr

Do not delete every directory named `360`. Games and asset libraries often use that number as an ID.

## WinToolBox ownership and evidence

`winToolBox` is an Aolande/Huajun-family third-party toolbox, not an official 360 application. Real samples have shown:

- `winLauncher.exe`, `WinTray.exe`, `kpicservice.exe`, `kstanddiskservice.exe`, and `fpprotect.exe` signed by `Beijing AoLanDe Information Technology Co., Ltd.`.
- Service names such as `KPICService_huajun`, `HJPDFSvc`, and `hjkstanddiskservice`.
- `KitTip.dll` and `cssdk.dll` signed by `Beijing Qihu Technology Co., Ltd.`; `cssdk.dll` may report `CompanyName=360.cn` and `ProductName=统计组件`.

Do not delete the complete `%LOCALAPPDATA%\winToolBox` tree merely because these mixed components exist.

A `Tools\SoftMgr*` subtree is confirmed when at least one of these holds:

- `softmgrsvr.exe` has `CompanyName` containing `360.cn`, `Qihoo`, or `Qihu`.
- It contains multiple markers such as `360Base.dll`, `360Conf.dll`, `360NetBase.dll`, or `360Util.dll`.
- Its `SoftMgrUpdate.exe` is used by a `SoftMgrUpdate*` scheduled task and a related 360 payload appeared at a matching time.

When confirmed, remove only:

- The confirmed `Tools\SoftMgr*` subtree.
- Scheduled tasks whose action points into that subtree.
- `WinToolBoxUpdateSrv` only when its executable is the exact `%LOCALAPPDATA%\winToolBox\winToolBoxSrv.exe` and SoftMgr evidence is confirmed.
- The exact `winToolBoxSrv.exe` updater binary after removing its service.
- Paired `greencore` and roaming `SoftMgr*` caches with matching evidence.

Preserve `Tools\kantu`, `Tools\clear`, `Tools\pdf`, and `Tools\zip` unless the user separately approves removing them.

## Persistence indicators

- Startup value `duohuipingbao` pointing to `...\dhpingbao\duohuipingbao.exe`.
- Startup value `sesvc` pointing to `...\360se6\...\sesvc.exe`.
- Scheduled tasks named `SoftMgrUpdate*` whose actions point to a confirmed SoftMgr subtree.
- Service `WinToolBoxUpdateSrv` with the exact validated updater path described above.
- Screen-saver value `SCRNSAVE.EXE` pointing into a confirmed Huabao/duohuipingbao directory.

Remove persistence only when both the entry and target match.

## Explorer lock indicators

Known DLLs include `qcnethelp64.dll`, `xhqcnethelp64.dll`, `SoftMgrExt64.dll`, and `analyst.dll`. The DLL name alone is insufficient. Confirm that its full path is under a confirmed target.

## Review-only drivers

Files such as `%WINDIR%\System32\drivers\360*.sys` and driver services require review. Do not automatically delete a `.sys` file or driver service. Prefer the product uninstaller, then verify the service and driver package with Windows-native tooling.

## Common false positives

- Windows files, component-store hashes, package IDs, and telemetry names containing `360`.
- iRacing/Steam/game map folders whose numeric asset ID is `360`.
- 360-degree photos, videos, panoramas, and camera folders.
- Model/resource names such as `u8_model_360`.
- Network ports, dimensions, build numbers, and cryptographic hashes.
- Windows screen savers: `Bubbles.scr`, `Mystify.scr`, `PhotoScreensaver.scr`, `Ribbons.scr`, and `scrnsave.scr`.
- Driver Genius (驱动精灵), which is separate from 360驱动大师.


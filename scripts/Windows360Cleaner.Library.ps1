#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows 360 Cleaner - UI logic library.
# Presentation logic, report/task file IO and a polled child-process runner for the guided selector.
# This file holds no WinForms types. It never deletes 360 targets, never elevates, never reboots,
# never registers autostart entries and never uploads anything. Removal is performed only by
# scripts/Invoke-360Cleanup.ps1 after the user explicitly approved a selection.

$script:W360ToolVersion = '1.0.0'
$script:W360UiLanguage = $null
$script:W360MaxSelectedIds = 64
# The "kept" list of the confirmation text stays short: this many lines plus a "N more" line.
$script:W360ConfirmKeptLineLimit = 10
$script:W360MaxRetainedLines = 2000
$script:W360ProgressLeafPattern = '^windows-360-cleaner-progress-[0-9a-f]{32}\.log$'
$script:W360TaskRecordType = 'Windows360CleanerTask'
$script:W360TaskFormatVersion = 1
$script:W360TaskNotice = 'This task record only locates reports for read-only verification. It is not an approval to remove anything.'
$script:W360HelpIssueUrl = 'https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml'
$script:W360ProductOrder = @(
    '360Security', '360InstallDir', '360SafeBrowser', '360ChromeBrowser', '360ChromeXBrowser', '360SoftMgr',
    'WinToolBox360', 'Duohui', '360GameAssistant', '360DriverMaster', 'GreenCore', '360Temp', '360Zip',
    '360Other', 'Drivers', 'OfflineWindows', 'Unattributed'
)
$script:W360KnownPhases = @(
    'ScanStart', 'ScanProductFolders', 'ScanVendorUninstaller', 'ScanToolbox', 'ScanInstalledPrograms',
    'ScanRegistryResidue', 'ScanStartup', 'ScanScheduledTasks', 'ScanServices', 'ScanDrivers', 'ScanProcesses',
    'ScanOfflineWindows', 'ScanComplete', 'SavingReport', 'Done', 'VerifyReadingPreviousReport',
    'VerifyCheckingTargets', 'ValidatingApproval', 'WaitingForElevation', 'ElevationCancelled', 'ElevationFailed',
    'ReadingOutcome', 'ElevatedStarted', 'RescanBeforeRemoval', 'ResolvingSelection', 'Preflight',
    'VendorUninstaller', 'RemovingServices', 'RemovingTasks', 'StoppingProcesses', 'RemovingRegistryValues',
    'RemovingRegistryKeys', 'RemovingPaths', 'RetryingLockedPaths', 'MeasuringResults', 'RescanAfterRemoval', 'Error'
)
# Any of these phases means the removal may already have reached (or passed) the elevation boundary.
$script:W360RemoveStartedPhases = @(
    'WaitingForElevation', 'ElevatedStarted', 'RescanBeforeRemoval', 'ResolvingSelection', 'Preflight',
    'VendorUninstaller', 'RemovingServices', 'RemovingTasks', 'StoppingProcesses', 'RemovingRegistryValues',
    'RemovingRegistryKeys', 'RemovingPaths', 'RetryingLockedPaths', 'MeasuringResults', 'RescanAfterRemoval',
    'SavingReport', 'Done'
)

# One localisation table for every user-visible string of the library (and the GUI built on it).
$script:W360Strings = @{
    'App.Name'                                   = @{ zh = 'Windows 360 清理工具'; en = 'Windows 360 Cleaner' }
    'App.WindowTitle'                            = @{ zh = 'Windows 360 清理工具 v{0}'; en = 'Windows 360 Cleaner v{0}' }
    'Common.None'                                = @{ zh = '（无）'; en = '(none)' }
    'Common.Unknown'                             = @{ zh = '未知'; en = 'Unknown' }
    'Common.Yes'                                 = @{ zh = '是'; en = 'Yes' }
    'Common.No'                                  = @{ zh = '否'; en = 'No' }
    'Common.NotRecorded'                         = @{ zh = '没有记录'; en = 'not recorded' }
    'Common.ListSeparator'                       = @{ zh = '、'; en = ', ' }
    'Common.SentenceSeparator'                   = @{ zh = ''; en = ' ' }
    'Common.MoreItems'                           = @{ zh = '……还有 {0} 项没有列出'; en = '... {0} more item(s) not listed' }

    'Status.AwaitingChoice.Text'                 = @{ zh = '可以删除'; en = 'Can be deleted' }
    'Status.AwaitingChoice.Explanation'          = @{ zh = '这是 360 留下的东西，删不删由你决定。删掉的东西不会放进回收站。'; en = 'This is something 360 left behind. You decide whether to delete it. Deleted items do not go to the Recycle Bin.' }
    # The "do not delete" prefix of every status text below; the confirmation dialog shows only the reason after it.
    'Status.KeepPrefix'                          = @{ zh = '不删除：'; en = "Won't delete: " }
    'Status.PersonalDataKept.Text'               = @{ zh = '不删除：书签和历史记录'; en = "Won't delete: bookmarks and history" }
    'Status.PersonalDataKept.Explanation'        = @{ zh = '这里是浏览器的书签、历史记录、保存的密码等个人资料，本工具不会删除。'; en = 'This holds browser bookmarks, history, saved passwords and other personal data. The tool does not delete it.' }
    'Status.OfflineReportOnly.Text'              = @{ zh = '不删除：在另一个 Windows 系统里'; en = "Won't delete: in another Windows installation" }
    'Status.OfflineReportOnly.Explanation'       = @{ zh = '这个东西在电脑上的另一个 Windows 系统里（例如另一块硬盘上）。本工具只列出来，不会删除。'; en = 'This is inside another Windows installation on this PC (for example on another disk). The tool only lists it and never deletes it.' }
    'Status.DriverReviewOnly.Text'               = @{ zh = '不删除：系统驱动'; en = "Won't delete: system driver" }
    'Status.DriverReviewOnly.Explanation'        = @{ zh = '直接删除系统驱动可能导致蓝屏或开不了机，所以本工具只列出来，不会删除。'; en = 'Deleting a system driver directly can cause blue screens or stop Windows from starting, so the tool only lists it and never deletes it.' }
    'Status.BundleKept.Text'                     = @{ zh = '不删除：这是别的软件'; en = "Won't delete: this is other software" }
    'Status.BundleKept.Explanation'              = @{ zh = '这是别的公司的软件，里面带了一部分 360 的东西。本工具不会删除整个软件，只列出里面单独的 360 部分。'; en = 'This is software from another company that contains some 360 parts. The tool never deletes the whole program; it only lists the separate 360 parts inside it.' }
    'Status.IdentityUnconfirmed.Text'            = @{ zh = '不删除：信息不完整'; en = "Won't delete: details incomplete" }
    'Status.IdentityUnconfirmed.Explanation'     = @{ zh = '没能确认这一项的详细信息，为了避免删错，先不删除。可以过一会儿重新检查电脑。'; en = 'The details of this item could not be confirmed, so it is not deleted to avoid deleting the wrong thing. You can check the PC again later.' }
    'Status.StillInstalled.Text'                 = @{ zh = '不删除：请先正常卸载'; en = "Won't delete: uninstall it normally first" }
    'Status.StillInstalled.Explanation'          = @{ zh = '这个软件看起来还装在电脑上。想删除的话，请先在 Windows“设置 → 应用”里卸载它，再重新检查电脑。'; en = 'This program still seems to be installed. To remove it, first uninstall it in Windows Settings > Apps, then check the PC again.' }
    'Status.InsufficientEvidence.Text'           = @{ zh = '不删除：不能确定是 360 的'; en = "Won't delete: not sure it belongs to 360" }
    'Status.InsufficientEvidence.Explanation'    = @{ zh = '名字或位置看起来像 360，但不能确定真的是 360 的。为了避免误删，不删除。'; en = 'The name or location looks like 360, but it is not certain that it really belongs to 360. It is not deleted to avoid deleting the wrong thing.' }
    'Status.MissingSelectionId.Text'             = @{ zh = '不删除：请重新检查'; en = "Won't delete: please check again" }
    'Status.MissingSelectionId.Explanation'      = @{ zh = '这份检查结果来自旧版本的工具，不能勾选。请重新检查电脑。'; en = 'This result comes from an older version of the tool and cannot be ticked. Please check the PC again.' }
    # A 360 item that could be deleted on its own, but never together with the rest of this check result
    # (Get-W360EffectiveDeletableIds): it is shown and treated as kept.
    'Status.KeptContentInside.Text'              = @{ zh = '不删除：里面有要保留的东西'; en = "Won't delete: it holds things that are kept" }
    'Status.KeptContentInside.Explanation'       = @{ zh = '它里面还有本工具不删除的东西。删除它会把那些东西一起删掉，所以它也不删除。'; en = 'It holds things the tool does not delete. Deleting it would delete those too, so it is not deleted either.' }
    'Status.NeedsItsFolder.Text'                 = @{ zh = '不删除：要和它所在的文件夹一起删'; en = "Won't delete: it goes together with its folder" }
    'Status.NeedsItsFolder.Explanation'          = @{ zh = '这是 360 自带的卸载程序，要和它所在的文件夹一起删除。那个文件夹不能删除，所以它也不删除。'; en = 'This is an uninstaller that came with 360. It can only be deleted together with its folder, and that folder cannot be deleted, so it is not deleted either.' }
    'Status.NotRemovable.Text'                   = @{ zh = '不删除'; en = "Won't delete" }
    'Status.NotRemovable.Explanation'            = @{ zh = '本工具不会删除这一项。'; en = 'The tool does not delete this item.' }

    'Kind.Folder'                                = @{ zh = '文件夹'; en = 'Folder' }
    'Kind.File'                                  = @{ zh = '文件'; en = 'File' }
    'Kind.OfflinePath'                           = @{ zh = '其他系统里的文件'; en = 'File in another Windows installation' }
    'Kind.VendorUninstaller'                     = @{ zh = '360 自带的卸载程序'; en = 'Uninstaller that came with 360' }
    'Kind.InstalledProduct'                      = @{ zh = 'Windows“设置 → 应用”列表里的记录'; en = 'Entry in the Windows Settings > Apps list' }
    'Kind.RegistryResidue'                       = @{ zh = '360 留下的设置'; en = 'Settings left by 360' }
    'Kind.Startup'                               = @{ zh = '开机自动运行'; en = 'Runs at startup' }
    'Kind.ScreenSaver'                           = @{ zh = '屏保设置'; en = 'Screen saver setting' }
    'Kind.ScheduledTask'                         = @{ zh = '定时自动运行的任务'; en = 'Task that runs on a timer' }
    'Kind.Service'                               = @{ zh = '后台服务'; en = 'Background service' }
    'Kind.Driver'                                = @{ zh = '系统驱动'; en = 'System driver' }
    'Kind.Process'                               = @{ zh = '正在运行的程序'; en = 'Running program' }
    'Kind.Bundle'                                = @{ zh = '带有 360 部分的其他软件'; en = 'Other software with 360 parts' }
    'Kind.Unknown'                               = @{ zh = '其他（{0}）'; en = 'Other ({0})' }

    'Product.360Security.Name'                   = @{ zh = '360 安全卫士 / 360 杀毒'; en = '360 Total Security / 360 Antivirus' }
    'Product.360Security.Description'            = @{ zh = '360 安全卫士、360 杀毒留下的程序文件和数据。'; en = 'Program files and data left by 360 Total Security or 360 Antivirus.' }
    'Product.360Security.Impact'                 = @{ zh = '删除后，这些 360 安全软件剩下的部分将无法使用，其中的设置和数据也会一起删除。'; en = 'Afterwards, what is left of these 360 security programs cannot be used, and their settings and data are deleted too.' }
    'Product.360InstallDir.Name'                 = @{ zh = '360 公共安装文件夹'; en = 'Shared 360 installation folder' }
    'Product.360InstallDir.Description'          = @{ zh = '电脑上放程序和公共数据的地方里的 360 文件夹，可能被好几个 360 软件共用。'; en = 'The 360 folders where Windows keeps programs and shared data; several 360 products may share them.' }
    'Product.360InstallDir.Impact'               = @{ zh = '里面可能同时有好几个 360 产品，删除后它们都无法再使用。'; en = 'Several 360 products may live inside; none of them can be used afterwards.' }
    'Product.360SafeBrowser.Name'                = @{ zh = '360 安全浏览器'; en = '360 Secure Browser' }
    'Product.360SafeBrowser.Description'         = @{ zh = '360 安全浏览器的程序文件和个人资料。'; en = 'Program files and personal data of 360 Secure Browser.' }
    'Product.360SafeBrowser.Impact'              = @{ zh = '删除程序文件后浏览器就打不开了。书签、历史记录等个人资料是单独的一项，默认保留。'; en = 'Without its program files the browser cannot start. Bookmarks, history and other personal data are a separate item that is kept by default.' }
    'Product.360ChromeBrowser.Name'              = @{ zh = '360 极速浏览器'; en = '360 Speed Browser (360Chrome)' }
    'Product.360ChromeBrowser.Description'       = @{ zh = '360 极速浏览器的程序文件和个人资料。'; en = 'Program files and personal data of 360 Speed Browser.' }
    'Product.360ChromeBrowser.Impact'            = @{ zh = '删除程序文件后浏览器就打不开了。书签、历史记录等个人资料是单独的一项，默认保留。'; en = 'Without its program files the browser cannot start. Bookmarks, history and other personal data are a separate item that is kept by default.' }
    'Product.360ChromeXBrowser.Name'             = @{ zh = '360 极速浏览器 X'; en = '360 Speed Browser X (360ChromeX)' }
    'Product.360ChromeXBrowser.Description'      = @{ zh = '360 极速浏览器 X 的程序文件和个人资料。'; en = 'Program files and personal data of 360 Speed Browser X.' }
    'Product.360ChromeXBrowser.Impact'           = @{ zh = '删除程序文件后浏览器就打不开了。书签、历史记录等个人资料是单独的一项，默认保留。'; en = 'Without its program files the browser cannot start. Bookmarks, history and other personal data are a separate item that is kept by default.' }
    'Product.360SoftMgr.Name'                    = @{ zh = '360 软件管家'; en = '360 Software Manager' }
    'Product.360SoftMgr.Description'             = @{ zh = '360 软件管家的程序文件和它下载的临时文件。'; en = 'Program files of 360 Software Manager and the files it downloaded.' }
    'Product.360SoftMgr.Impact'                  = @{ zh = '删除后 360 软件管家不能再用，它下载的临时文件也会删掉。'; en = '360 Software Manager cannot be used afterwards, and the files it downloaded are deleted too.' }
    'Product.WinToolBox360.Name'                 = @{ zh = 'winToolBox 工具箱里的 360 部分'; en = '360 parts inside winToolBox' }
    'Product.WinToolBox360.Description'          = @{ zh = 'winToolBox 是别的公司的工具箱，里面带有 360 软件管家等部分。本工具只让你选择里面单独的 360 部分，不会删除整个工具箱。'; en = 'winToolBox is a toolbox from another company that ships 360 Software Manager parts. The tool only lets you select the separate 360 parts and never deletes the whole toolbox.' }
    'Product.WinToolBox360.Impact'               = @{ zh = 'winToolBox 的自动更新，或者用到这些部分的功能可能不能用；它自己的看图、清理、PDF、压缩等小工具会保留。'; en = 'winToolBox auto-update or features that use these parts may stop working; its own image viewer, cleaner, PDF and zip tools are kept.' }
    'Product.Duohui.Name'                        = @{ zh = '360 画报 / 多绘屏保'; en = '360 Huabao / Duohui screen saver' }
    'Product.Duohui.Description'                 = @{ zh = '多绘屏保（360 画报）的安装文件夹、临时安装包、卸载记录和留下的设置。'; en = 'Installation folder, temporary installer files, uninstall record and leftover settings of the Duohui screen saver (360 Huabao).' }
    'Product.Duohui.Impact'                      = @{ zh = '删除后多绘屏保和它的壁纸功能不能再使用。'; en = 'The Duohui screen saver and its wallpaper features cannot be used afterwards.' }
    'Product.360GameAssistant.Name'              = @{ zh = '360 游戏助手 / 游戏大厅'; en = '360 Game Assistant' }
    'Product.360GameAssistant.Description'       = @{ zh = '360 游戏助手的文件和临时文件。'; en = 'Files and temporary files of 360 Game Assistant.' }
    'Product.360GameAssistant.Impact'            = @{ zh = '删除后 360 游戏助手无法再使用。'; en = '360 Game Assistant cannot be used afterwards.' }
    'Product.360DriverMaster.Name'               = @{ zh = '360 驱动大师'; en = '360 Driver Master' }
    'Product.360DriverMaster.Description'        = @{ zh = '360 驱动大师留下的屏保程序等文件。'; en = 'Files such as the screen saver program left by 360 Driver Master.' }
    'Product.360DriverMaster.Impact'             = @{ zh = '删除后这些程序不能再用。已经装进 Windows 的系统驱动不会被删除。'; en = 'These programs cannot be used afterwards. System drivers already installed in Windows are not deleted.' }
    'Product.GreenCore.Name'                     = @{ zh = '360 GreenCore 下载的文件'; en = '360 GreenCore downloads' }
    'Product.GreenCore.Description'              = @{ zh = '360 软件用 GreenCore 下载的临时文件和压缩包。'; en = 'Temporary files and archives that 360 software downloaded with GreenCore.' }
    'Product.GreenCore.Impact'                   = @{ zh = '删掉的只是下载的临时文件。还在用它的 360 软件可能会重新下载。'; en = 'Only downloaded temporary files are deleted. A 360 program that still uses them may download them again.' }
    'Product.360Temp.Name'                       = @{ zh = '360 临时文件'; en = '360 temporary files' }
    'Product.360Temp.Description'                = @{ zh = '360 安装或解压时留下的临时文件。'; en = 'Temporary files left while installing or unpacking 360 software.' }
    'Product.360Temp.Impact'                     = @{ zh = '只是临时文件，删除一般不影响其他软件。'; en = 'These are temporary files; deleting them normally does not affect other software.' }
    'Product.360Zip.Name'                        = @{ zh = '360 压缩'; en = '360 Zip' }
    'Product.360Zip.Description'                 = @{ zh = '360 压缩留下的记录和文件。'; en = 'Records and files left by 360 Zip.' }
    'Product.360Zip.Impact'                      = @{ zh = '删除后 360 压缩剩下的部分不能再使用。'; en = 'What is left of 360 Zip cannot be used afterwards.' }
    'Product.360Other.Name'                      = @{ zh = '其他 360 产品'; en = 'Other 360 products' }
    'Product.360Other.Description'               = @{ zh = '其他 360 产品（例如 360 桌面助手、360 壁纸）留下的记录。'; en = 'Records left by other 360 products (for example 360 Desktop Assistant or 360 Wallpaper).' }
    'Product.360Other.Impact'                    = @{ zh = '删除后对应产品剩下的部分不能再使用。'; en = 'What is left of those products cannot be used afterwards.' }
    'Product.Drivers.Name'                       = @{ zh = '360 系统驱动'; en = '360 system drivers' }
    'Product.Drivers.Description'                = @{ zh = '360 装进 Windows 的系统驱动。'; en = 'System drivers that 360 installed into Windows.' }
    'Product.Drivers.Impact'                     = @{ zh = '本工具不会删除系统驱动，只列出来给你看。'; en = 'The tool never deletes system drivers; it only lists them.' }
    'Product.OfflineWindows.Name'                = @{ zh = '其他 Windows 系统里的内容'; en = 'Items in another Windows installation' }
    'Product.OfflineWindows.Description'         = @{ zh = '在另一个 Windows 系统（例如另一块硬盘）里找到的 360 文件。'; en = '360 files found in another Windows installation (for example on another disk).' }
    'Product.OfflineWindows.Impact'              = @{ zh = '本工具只列出来，不会删除。'; en = 'The tool only lists them and never deletes them.' }
    'Product.Unattributed.Name'                  = @{ zh = '说不清属于哪个 360 软件'; en = 'Not sure which 360 product' }
    'Product.Unattributed.Description'           = @{ zh = '只是名字像 360，或者没法判断它属于哪个 360 软件。本工具不会乱猜。'; en = 'Only the name looks like 360, or it is unclear which 360 product it belongs to. The tool does not guess.' }
    'Product.Unattributed.Impact'                = @{ zh = '这里的内容大多不删除；能删除的请看每一项的说明。'; en = 'Most of these items are kept; see each item for details.' }

    'Name.ProgramFiles360'                       = @{ zh = '360 程序文件夹'; en = '360 program folder' }
    'Name.ProgramFilesX86360'                    = @{ zh = '360 程序文件夹（32 位）'; en = '360 program folder (32-bit)' }
    'Name.ProgramData360'                        = @{ zh = '360 公共数据文件夹'; en = '360 shared data folder' }
    'Name.ProgramData360Safe'                    = @{ zh = '360 安全卫士公共数据文件夹'; en = '360 Total Security shared data folder' }
    'Name.ChromeApplication'                     = @{ zh = '360 极速浏览器程序文件'; en = '360 Speed Browser program files' }
    'Name.ChromeProfile'                         = @{ zh = '360 极速浏览器个人资料（书签、历史等）'; en = '360 Speed Browser personal data (bookmarks, history, ...)' }
    'Name.ChromeXApplication'                    = @{ zh = '360 极速浏览器 X 程序文件'; en = '360 Speed Browser X program files' }
    'Name.ChromeXProfile'                        = @{ zh = '360 极速浏览器 X 个人资料（书签、历史等）'; en = '360 Speed Browser X personal data (bookmarks, history, ...)' }
    'Name.DuohuiInstall'                         = @{ zh = '多绘屏保安装文件夹'; en = 'Duohui screen saver installation folder' }
    'Name.Se6Application'                        = @{ zh = '360 安全浏览器程序文件'; en = '360 Secure Browser program files' }
    'Name.Se6Profile'                            = @{ zh = '360 安全浏览器个人资料（书签、历史等）'; en = '360 Secure Browser personal data (bookmarks, history, ...)' }
    'Name.LegacyBrowserProfile'                  = @{ zh = '旧版 360 浏览器个人资料（书签、历史等）'; en = 'Legacy 360 browser personal data (bookmarks, history, ...)' }
    'Name.SoftMgrUiKernel'                       = @{ zh = '360 软件管家界面文件'; en = '360 Software Manager interface files' }
    'Name.RoamingSafe'                           = @{ zh = '360 安全卫士用户数据文件夹'; en = '360 Total Security user data folder' }
    'Name.GameAssistant'                         = @{ zh = '360 游戏助手文件夹'; en = '360 Game Assistant folder' }
    'Name.Huabao'                                = @{ zh = '360 画报文件夹'; en = '360 Huabao folder' }
    'Name.DriverMasterScreenSaver'               = @{ zh = '360 驱动大师屏保文件夹'; en = '360 Driver Master screen saver folder' }
    'Name.GreenCore'                             = @{ zh = 'GreenCore 下载文件夹'; en = 'GreenCore download folder' }
    'Name.GreenCore7z'                           = @{ zh = 'GreenCore 压缩包文件夹'; en = 'GreenCore archive folder' }
    'Name.DuohuiTemp'                            = @{ zh = '多绘屏保临时安装包'; en = 'Duohui temporary installer files' }
    'Name.HuabaoTemp'                            = @{ zh = '360 画报临时安装包'; en = '360 Huabao temporary installer files' }
    'Name.GameAssistantTemp'                     = @{ zh = '360 游戏助手临时文件'; en = '360 Game Assistant temporary files' }
    'Name.UnpackTemp'                            = @{ zh = '360 解压临时文件'; en = '360 unpack temporary files' }
    'Name.DuohuiVendorUninstaller'               = @{ zh = '多绘屏保自带的卸载程序'; en = 'Uninstaller that came with the Duohui screen saver' }
    'Name.TempCab'                               = @{ zh = '360 临时安装包'; en = '360 temporary installer package' }
    'Name.ToolboxSoftMgr'                        = @{ zh = 'winToolBox 工具箱里的 360 软件管家'; en = '360 Software Manager inside winToolBox' }
    'Name.ToolboxAmbiguousSoftMgr'               = @{ zh = 'winToolBox 工具箱里来源不明的 SoftMgr 文件夹'; en = 'SoftMgr folder of unclear origin inside winToolBox' }
    'Name.ToolboxSignedComponent'                = @{ zh = 'winToolBox 工具箱里的 360 程序文件（{0}）'; en = '360 program file inside winToolBox ({0})' }
    'Name.ToolboxBundle'                         = @{ zh = 'winToolBox 工具箱（整个软件）'; en = 'winToolBox toolbox (the whole program)' }
    'Name.ToolboxUpdater'                        = @{ zh = 'winToolBox 自动更新程序'; en = 'winToolBox auto-updater' }
    'Name.RoamingSoftMgr'                        = @{ zh = '360 软件管家下载文件夹'; en = '360 Software Manager download folder' }
    'Name.ProgramFilesSoftMgr'                   = @{ zh = '360 软件管家程序文件夹'; en = '360 Software Manager program folder' }
    'Name.DuohuiRegistryResidue'                 = @{ zh = '多绘屏保留下的设置'; en = 'Settings left by the Duohui screen saver' }
    'Name.OfflineWindowsPath'                    = @{ zh = '其他 Windows 系统里的 360 文件夹'; en = '360 folder in another Windows installation' }
    'Name.OfflineUserPath'                       = @{ zh = '其他 Windows 系统用户的 360 文件夹'; en = '360 folder of a user in another Windows installation' }
    'Name.InstalledProductRecord'                = @{ zh = '{0} 的卸载记录'; en = 'Uninstall record of {0}' }
    'Name.InstalledProductUnnamed'               = @{ zh = '360 系列软件的卸载记录'; en = 'Uninstall record of a 360 program' }
    'Name.ScreenSaverSetting'                    = @{ zh = '屏幕保护程序设置'; en = 'Screen saver setting' }
    'Name.WithKind'                              = @{ zh = '{0}：{1}'; en = '{0}: {1}' }
    # Plain names of deletion problems whose target matches no selected item (the raw target is in Details only).
    'Name.Problem.Service'                       = @{ zh = '一个后台服务'; en = 'A background service' }
    'Name.Problem.Task'                          = @{ zh = '一个定时自动运行的任务'; en = 'A task that runs on a timer' }
    'Name.Problem.Process'                       = @{ zh = '一个正在运行的程序'; en = 'A running program' }
    'Name.Problem.Registry'                      = @{ zh = '360 留下的一条设置'; en = 'A setting left by 360' }
    'Name.Problem.Uninstaller'                   = @{ zh = '360 自带的卸载程序'; en = 'The uninstaller that came with 360' }
    'Name.Problem.Path'                          = @{ zh = '一些文件'; en = 'Some files' }
    'Name.Problem.Other'                         = @{ zh = '其他一项'; en = 'Another item' }
}

$script:W360StringsPartB = @{
    'Reason.None'                                = @{ zh = '没有记录判断依据。'; en = 'No reason was recorded.' }
    'Reason.Unmapped'                            = @{ zh = '原始判断依据（英文）：{0}'; en = 'Original reason (English): {0}' }
    'Reason.Evidence.Found'                      = @{ zh = '，并且找到了 360（奇虎）的文件证据。'; en = ', and 360/Qihoo file evidence was found.' }
    'Reason.Evidence.Missing'                    = @{ zh = '，但没有找到应有的 360（奇虎）文件证据，所以只供查看。'; en = ', but the expected 360/Qihoo file evidence was not found, so it is for review only.' }
    'Reason.VendorProductDirectory'              = @{ zh = '这是 360 产品的标准安装目录'; en = 'This is the standard 360 product installation folder' }
    'Reason.VendorDataDirectory'                 = @{ zh = '这是 360 的标准数据目录'; en = 'This is the standard 360 data folder' }
    'Reason.SafeDataDirectory'                   = @{ zh = '这是 360 安全卫士的标准数据目录'; en = 'This is the standard 360 Total Security data folder' }
    'Reason.ChromeApplication'                   = @{ zh = '这是 360 极速浏览器的标准程序目录'; en = 'This is the standard program folder of 360 Speed Browser' }
    'Reason.ChromeXApplication'                  = @{ zh = '这是 360 极速浏览器 X 的标准程序目录'; en = 'This is the standard program folder of 360 Speed Browser X' }
    'Reason.Se6Application'                      = @{ zh = '这是 360 安全浏览器的标准程序目录'; en = 'This is the standard program folder of 360 Secure Browser' }
    'Reason.ChromeProfile'                       = @{ zh = '这是 360 极速浏览器的个人资料目录，里面可能有书签、历史记录、保存的会话等个人数据。'; en = 'This is the personal data folder of 360 Speed Browser. It can hold bookmarks, history, saved sessions and other personal data.' }
    'Reason.ChromeXProfile'                      = @{ zh = '这是 360 极速浏览器 X 的个人资料目录，里面可能有书签、历史记录、保存的会话等个人数据。'; en = 'This is the personal data folder of 360 Speed Browser X. It can hold bookmarks, history, saved sessions and other personal data.' }
    'Reason.Se6Profile'                          = @{ zh = '这是 360 安全浏览器的个人资料目录，里面可能有书签、历史记录、保存的会话等个人数据。'; en = 'This is the personal data folder of 360 Secure Browser. It can hold bookmarks, history, saved sessions and other personal data.' }
    'Reason.LegacyBrowserProfile'                = @{ zh = '这是旧版 360 浏览器的个人资料目录，里面可能有书签、历史记录、保存的会话等个人数据。'; en = 'This is the personal data folder of a legacy 360 browser. It can hold bookmarks, history, saved sessions and other personal data.' }
    'Reason.DuohuiInstallPath'                   = @{ zh = '这是多绘屏保（duohuipingbao）的已知安装位置。'; en = 'This is the known installation location of the Duohui screen saver (duohuipingbao).' }
    'Reason.SoftMgrUiKernel'                     = @{ zh = '这是 360 软件管家界面组件（secoresdk\360se6）的标准目录'; en = 'This is the standard folder of the 360 Software Manager interface component (secoresdk\360se6)' }
    'Reason.CurrentUserPath'                     = @{ zh = '这是当前用户下的 360 标准目录'; en = 'This is a standard 360 folder of the current user' }
    'Reason.GreenCoreCache'                      = @{ zh = '这是 GreenCore 缓存目录；只有找到 360greencore 标记时才会被识别。'; en = 'This is the GreenCore cache folder; it is identified only when a 360greencore marker is found.' }
    'Reason.GreenCoreArchive'                    = @{ zh = '这是 GreenCore 压缩包缓存目录；只有找到 360 标记时才会被识别。'; en = 'This is the GreenCore archive cache folder; it is identified only when a 360 marker is found.' }
    'Reason.DuohuiStaging'                       = @{ zh = '这是多绘屏保安装时使用的已知临时目录。'; en = 'This is the known temporary folder used while installing the Duohui screen saver.' }
    'Reason.HuabaoStaging'                       = @{ zh = '这是 360 画报安装程序使用的已知临时目录。'; en = 'This is the known temporary folder used by the 360 Huabao installer.' }
    'Reason.TemporaryComponent'                  = @{ zh = '这是 360 组件的标准临时目录'; en = 'This is a standard temporary folder of a 360 component' }
    'Reason.VendorUninstallerConfirmed'          = @{ zh = '这是多绘屏保自带的卸载程序：它位于已识别的 dhpingbao 目录中，带有有效的“北京奇虎科技有限公司”数字签名和多绘屏保/画报的文件信息，文件指纹（SHA-256）已经记录。'; en = 'This is the built-in Duohui uninstaller: it is inside the identified dhpingbao folder, has a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao file information, and its SHA-256 fingerprint was recorded.' }
    'Reason.VendorUninstallerPathUnsafe'         = @{ zh = '找到了多绘屏保卸载程序文件，但它所在的路径没有通过安全检查，无法确认它的身份，所以不会运行它。'; en = 'The Duohui uninstaller file exists, but its folder path did not pass the safety check, so its identity cannot be confirmed and it will not be run.' }
    'Reason.VendorUninstallerHashUnreadable'     = @{ zh = '找到了多绘屏保卸载程序文件，但无法安全地读取它的文件指纹（SHA-256），无法确认它的身份，所以不会运行它。'; en = 'The Duohui uninstaller file exists, but its SHA-256 fingerprint could not be read safely, so its identity cannot be confirmed and it will not be run.' }
    'Reason.VendorUninstallerPathChainUnsafe'    = @{ zh = '卸载程序所在的路径没有通过安全检查。'; en = 'The folder path of the uninstaller did not pass the safety check.' }
    'Reason.VendorUninstallerNotTrusted'         = @{ zh = '找到了多绘屏保卸载程序文件，但缺少下面至少一项：已识别的 dhpingbao 安装目录、有效的发行商签名和文件信息、有效的文件指纹。为了安全，不会运行它。'; en = 'The Duohui uninstaller file exists, but at least one of these is missing: an identified dhpingbao folder, a valid publisher signature with file information, or a valid fingerprint. For safety it will not be run.' }
    'Reason.TempCabName'                         = @{ zh = '文件名看起来像 360 的安装包（CAB），但只凭文件名不足以证明它属于 360。'; en = 'The file name looks like a 360 installer package (CAB), but a name alone does not prove it belongs to 360.' }
    'Reason.ToolboxSoftMgr'                      = @{ zh = '这个 SoftMgr 文件夹里有带 360 签名或能识别为 360 的程序文件。winToolBox 本身是第三方软件。'; en = 'This SoftMgr folder contains program files signed by or identified as 360. winToolBox itself is third-party software.' }
    'Reason.ToolboxAmbiguousSoftMgr'             = @{ zh = '文件夹名叫 SoftMgr，但没有找到能确定属于 360 的标记。'; en = 'The folder is named SoftMgr, but no marker proves that it belongs to 360.' }
    'Reason.ToolboxSignedComponent'              = @{ zh = '这个文件带有 360（奇虎）的数字签名，或能识别为 360 组件。签名者：{0}'; en = 'This file is signed by or identified as a 360/Qihoo component. Signer: {0}' }
    'Reason.ToolboxBundle'                       = @{ zh = '这个第三方工具箱里有已识别的 360 组件。整个工具箱不能在这里删除，需要你另外单独决定。'; en = 'This third-party toolbox contains identified 360 components. The whole toolbox cannot be removed here; that needs a separate decision.' }
    'Reason.ToolboxUpdater'                      = @{ zh = '这是 winToolBox 的自动更新程序，它和电脑上已识别的 360 软件管家下载链有关。'; en = 'This is the winToolBox auto-updater, which is tied to the identified 360 Software Manager download chain on this PC.' }
    'Reason.RoamingSoftMgrConfirmed'             = @{ zh = '这个缓存目录和已识别的 360 软件管家证据相对应。'; en = 'This cache folder matches identified 360 Software Manager evidence.' }
    'Reason.RoamingSoftMgrUnconfirmed'           = @{ zh = '名字是 SoftMgr，但电脑上没有足够的 360 证据。'; en = 'The name is SoftMgr, but there is not enough 360 evidence on this PC.' }
    'Reason.ProgramFilesSoftMgrConfirmed'        = @{ zh = '找到了 360 产品的文件信息或 DLL 标记。'; en = '360 product file information or DLL markers were found.' }
    'Reason.ProgramFilesSoftMgrUnconfirmed'      = @{ zh = '这个 SoftMgr 文件夹来源不明，没有找到足够的标记。'; en = 'This SoftMgr folder is of unclear origin and has too few markers.' }
    'Reason.OrphanUninstallRecord'               = @{ zh = '这是一条 360 系列软件的卸载记录。它指向的文件已经不存在，也没有可用的安装目录或卸载程序，是一条失效记录。'; en = 'This is an uninstall record of a 360 program. The files it points to are gone and there is no working install folder or uninstaller, so the record is stale.' }
    'Reason.LiveVendorUninstaller'               = @{ zh = '这个 360 系列软件的卸载程序还在。应该先用它自带的卸载程序卸载，而不是直接删除记录。'; en = 'The uninstaller of this 360 program still exists. Use that uninstaller first instead of deleting the record.' }
    'Reason.LiveInstallLocation'                 = @{ zh = '这个 360 系列软件的安装目录还在。建议先检查，并优先使用它自带的卸载程序。'; en = 'The install folder of this 360 program still exists. Check it first and prefer its own uninstaller.' }
    'Reason.UninstallRecordNotProven'            = @{ zh = '没有足够证据证明这条卸载记录已经失效，需要先检查它指向的文件。'; en = 'There is not enough evidence that this uninstall record is stale; the files it points to need to be checked first.' }
    'Reason.DuohuiResidueConfirmed'              = @{ zh = '这是多绘屏保留下的注册表残留，并且已经确认它对应的卸载记录是失效的。'; en = 'This is registry residue of the Duohui screen saver, and its matching uninstall record was confirmed to be stale.' }
    'Reason.DuohuiResidueUnconfirmed'            = @{ zh = '这是多绘屏保的注册表残留，但没能确认它对应的卸载记录已经失效，所以只供查看。'; en = 'This is registry residue of the Duohui screen saver, but its uninstall record was not confirmed to be stale, so it is for review only.' }
    'Reason.StartupUnderTarget'                  = @{ zh = '这个开机启动项要运行的程序位于已识别的目录中：{0}'; en = 'The program this startup entry runs is inside an identified folder: {0}' }
    'Reason.StartupNameOnly'                     = @{ zh = '启动项的名字或路径里有 360 相关字样，但它要运行的程序不在已识别的目录中。'; en = 'The startup entry name or path mentions 360, but the program it runs is not inside an identified folder.' }
    'Reason.ScreenSaverUnderTarget'              = @{ zh = '屏幕保护程序设置指向已识别的目录。'; en = 'The screen saver setting points into an identified folder.' }
    'Reason.TaskUnderTarget'                     = @{ zh = '这个计划任务要运行的程序位于已识别的目录中。'; en = 'The program this scheduled task runs is inside an identified folder.' }
    'Reason.TaskNameOnly'                        = @{ zh = '计划任务的名字里有 360 相关字样，但它要运行的程序不在已识别的目录中。'; en = 'The scheduled task name mentions 360, but the program it runs is not inside an identified folder.' }
    'Reason.ServiceUnderTarget'                  = @{ zh = '这个系统服务运行的程序位于已识别的目录中，或者就是已识别的 winToolBox 自动更新程序。'; en = 'The program this service runs is inside an identified folder, or it is the identified winToolBox auto-updater.' }
    'Reason.ServiceToolboxSibling'               = @{ zh = '这个服务属于 winToolBox 工具箱，但它不是已识别的 360 组件，所以不在这里处理。'; en = 'This service belongs to winToolBox, but it is not an identified 360 component, so it is not handled here.' }
    'Reason.ServiceNameOnly'                     = @{ zh = '服务的名字或路径里有 360 相关字样，但它运行的程序不在已识别的目录中。'; en = 'The service name or path mentions 360, but the program it runs is not inside an identified folder.' }
    'Reason.Driver'                              = @{ zh = '这是系统驱动程序，需要用厂商卸载程序或驱动管理工具处理，本工具不会删除。'; en = 'This is a system driver. It needs the vendor uninstaller or a driver tool; this tool never deletes it.' }
    'Reason.ProcessUnderTarget'                  = @{ zh = '这个正在运行的程序位于已识别的目录中：{0}'; en = 'This running program is inside an identified folder: {0}' }
    'Reason.OfflineWindows'                      = @{ zh = '在另一个 Windows 系统里发现。对其他系统，本工具只扫描，不处理。'; en = 'Found in another Windows installation. For other installations the tool only scans and never changes anything.' }
    'Reason.OfflineUser'                         = @{ zh = '在另一个 Windows 系统的用户文件夹里发现。只扫描，不处理。'; en = 'Found in a user folder of another Windows installation. Scan only.' }
    'Reason.Suffix.EvidenceMissing'              = @{ zh = '但没有找到应有的产品文件证据，所以只供查看。'; en = 'However, the expected product evidence was not found, so it is for review only.' }
    'Reason.Suffix.ProfilePreserved'             = @{ zh = '默认保留，不会删除。'; en = 'It is kept by default and not deleted.' }
    'Reason.Suffix.IdentityMissing'              = @{ zh = '但没能准确记录它的身份信息，为了安全不会处理。'; en = 'However, its exact identity could not be recorded, so for safety it is not handled.' }

    # The permanence ("not moved to the Recycle Bin") is said once per window (item description, red confirmation line).
    'Impact.BrowserApplication'                  = @{ zh = '删除后这个浏览器就打不开了。书签、历史记录等个人资料是单独的一项，默认不删。'; en = 'The browser cannot start afterwards. Bookmarks, history and other personal data are a separate item that is not deleted by default.' }
    'Impact.BrowserProfile'                      = @{ zh = '会删掉这个浏览器的书签、历史记录、保存的密码、打开的网页和扩展程序，删掉后找不回来。请先备份需要的资料。'; en = 'The browser bookmarks, history, saved passwords, open pages and extensions are deleted and cannot be recovered. Back up anything you need first.' }
    'Impact.VendorUninstaller'                   = @{ zh = '会运行多绘屏保自带的卸载程序。它可能把多绘屏保里你没勾选的部分也删掉，本工具没法保证没勾选的不受影响。'; en = 'The uninstaller that came with the Duohui screen saver is run. It may also remove Duohui parts you did not tick; the tool cannot guarantee that unticked items stay untouched.' }
    # Short form for the confirmation dialog, which states the unticked-items warning on its own line.
    'Impact.VendorUninstaller.Confirm'           = @{ zh = '会运行多绘屏保自带的卸载程序，它删掉的东西找不回来。'; en = 'The uninstaller that came with the Duohui screen saver is run; what it removes cannot be recovered.' }
    'Impact.SharedInstallDir'                    = @{ zh = '里面可能同时有好几个 360 软件，里面的东西会全部删掉，这些软件都不能再用。'; en = 'Several 360 products may live inside; everything inside is deleted and none of them can be used afterwards.' }
    'Impact.Service'                             = @{ zh = '会先停止这个后台服务再删掉它，以后它不会再自动运行。'; en = 'This background service is stopped and then deleted, so it no longer runs automatically.' }
    'Impact.Task'                                = @{ zh = '会删掉这个定时自动运行的任务，它不会再按时下载或启动程序。'; en = 'This task that runs on a timer is deleted, so it no longer downloads or starts programs.' }
    'Impact.Startup'                             = @{ zh = '只删掉这一条开机自动运行的设置，开机时不再自动运行它；程序文件本身不会因为这一项被删掉。'; en = 'Only this startup setting is deleted, so it no longer runs at sign-in; the program files are not touched by this item.' }
    'Impact.ScreenSaver'                         = @{ zh = '会删掉屏幕保护程序设置，Windows 会恢复成“无屏幕保护程序”。'; en = 'The screen saver setting is deleted and Windows goes back to no screen saver.' }
    'Impact.Process'                             = @{ zh = '会关掉这个正在运行的程序，才能删掉它的文件。里面没保存的内容会丢失，请先保存。'; en = 'This running program is closed so that its files can be deleted. Unsaved work in it is lost, so save first.' }
    'Impact.OrphanUninstallRecord'               = @{ zh = '会从 Windows“设置 → 应用”列表里删掉一条已经没用的卸载记录；对应的程序文件已经不在了。'; en = 'An entry that no longer works is removed from the Windows Settings > Apps list; the program files are already gone.' }
    'Impact.RegistryResidue'                     = @{ zh = '会删掉 360 留下的这一组设置，它只是软件留下的设置。'; en = 'This group of settings left by 360 is deleted; it only holds leftover program settings.' }
    'Impact.RegistryValue'                       = @{ zh = '只删掉这一条设置。'; en = 'Only this one setting is deleted.' }
    'Impact.WinToolBoxUpdater'                   = @{ zh = '会删掉 winToolBox 的自动更新程序，winToolBox 可能不能自动更新了；它自己的看图、清理、PDF、压缩等小工具会保留。'; en = 'The winToolBox auto-updater is deleted, so winToolBox may no longer update itself; its own image viewer, cleaner, PDF and zip tools are kept.' }
    'Impact.WinToolBoxComponent'                 = @{ zh = '会删掉 winToolBox 里的这个 360 部分，用到它的 winToolBox 功能可能不能用；它自己的看图、清理、PDF、压缩等小工具会保留。'; en = 'This 360 part inside winToolBox is deleted, so winToolBox features that use it may stop working; its own image viewer, cleaner, PDF and zip tools are kept.' }
    'Impact.TempFiles'                           = @{ zh = '只是临时文件，一般不影响别的软件。'; en = 'These are only temporary files; other software is normally not affected.' }
    'Impact.Folder'                              = @{ zh = '这个文件夹和里面的东西会全部删掉。'; en = 'This folder and everything inside it are deleted.' }
    'Impact.File'                                = @{ zh = '这个文件会被删掉。'; en = 'This file is deleted.' }
    'Impact.Generic'                             = @{ zh = '这一项会被删掉。'; en = 'This item is deleted.' }
    'Impact.Kept'                                = @{ zh = '不会删除。'; en = 'It will not be deleted.' }
    'Impact.Kept.Profile'                        = @{ zh = '不会删除。你的书签、历史记录等个人资料会保留。'; en = 'It will not be deleted. Your bookmarks, history and other personal data are kept.' }
    'Impact.Kept.Offline'                        = @{ zh = '不会删除。另一个 Windows 系统里的内容，本工具只列出来。'; en = 'It will not be deleted. The tool only lists content of other Windows installations.' }
    'Impact.Kept.Driver'                         = @{ zh = '不会删除。系统驱动要用 360 自带的卸载程序或驱动管理工具来处理。'; en = 'It will not be deleted. System drivers need the uninstaller that came with 360 or a driver tool.' }
    'Impact.Kept.Bundle'                         = @{ zh = '不会删除。整个软件都会保留。'; en = 'It will not be deleted. The whole program is kept.' }

    'Tech.Confidence'                            = @{ zh = '识别结果（Confidence）：'; en = 'Confidence: ' }
    'Tech.Kind'                                  = @{ zh = '类型（Kind）：'; en = 'Kind: ' }
    'Tech.Name'                                  = @{ zh = '名称（Name）：'; en = 'Name: ' }
    'Tech.Target'                                = @{ zh = '位置（Target）：'; en = 'Target: ' }
    'Tech.ValueName'                             = @{ zh = '附加值（ValueName）：'; en = 'ValueName: ' }
    'Tech.RemovalType'                           = @{ zh = '处理方式（RemovalType）：'; en = 'RemovalType: ' }
    'Tech.ProductKey'                            = @{ zh = '所属产品（ProductKey）：'; en = 'ProductKey: ' }
    'Tech.SelectionId'                           = @{ zh = '选择标识（SelectionId）：'; en = 'SelectionId: ' }
    'Tech.IdentityFingerprint'                   = @{ zh = '身份指纹（IdentityFingerprint）：'; en = 'IdentityFingerprint: ' }
    'Tech.Offline'                               = @{ zh = '其他系统（Offline）：'; en = 'Offline: ' }
    'Tech.Reason'                                = @{ zh = '原始判断依据（英文 Reason）：'; en = 'Reason (original): ' }

    'Plan.NothingSelected.Message'               = @{ zh = '还没有勾选任何内容。'; en = 'Nothing is ticked yet.' }
    'Plan.NothingSelected.Resolution'            = @{ zh = '请先勾选要删除的内容；不想删除的话，直接关闭窗口就行。'; en = 'Tick the items you want to delete first. If you do not want to delete anything, just close the window.' }
    'Plan.TooMany.Message'                       = @{ zh = '你勾选了 {0} 项，一次最多只能删除 {1} 项。'; en = 'You ticked {0} items, but at most {1} items can be deleted at a time.' }
    'Plan.TooMany.Resolution'                    = @{ zh = '先取消一部分勾选（比如一次只删一个软件），删完后重新检查电脑，再删下一批。'; en = 'Untick some items (for example delete one product at a time), check the PC again after deleting, then delete the next batch.' }
    'Plan.UnknownId.Message'                     = @{ zh = '有一项勾选和这次检查结果不一致。'; en = 'One ticked item does not match this check result.' }
    'Plan.UnknownId.Resolution'                  = @{ zh = '请点“全部不选”后重新勾选；还是不行的话，请重新检查电脑。'; en = 'Click "Clear all" and tick again; if that does not help, check the PC again.' }
    'Plan.ParentContainsSelectableChild.Message' = @{ zh = '“{0}”里面还有你没勾选的“{2}”（共 {1} 项）。删除“{0}”会把它们一起删掉。'; en = '"{0}" contains "{2}" ({1} item(s) in total) that you did not tick. Deleting "{0}" deletes them too.' }
    'Plan.ParentContainsSelectableChild.Resolution' = @{ zh = '可以把它们也勾上，或者不删“{0}”。'; en = 'Tick them as well, or do not delete "{0}".' }
    'Plan.ParentContainsProtectedChild.Message'  = @{ zh = '“{0}”里面有要保留的“{2}”（共 {1} 项），所以“{0}”不能整个删掉。'; en = '"{0}" contains "{2}" ({1} item(s) in total) that must be kept, so "{0}" cannot be deleted as a whole.' }
    'Plan.ParentContainsProtectedChild.Resolution' = @{ zh = '请不要勾选“{0}”，这样里面要保留的东西才不会被删掉。'; en = 'Do not tick "{0}", so that what must be kept inside it is not deleted.' }
    'Plan.VendorUninstallerNeedsInstallRoot.Message' = @{ zh = '你勾选了“{0}”，但没有勾选它所在的文件夹“{1}”。360 自带的卸载程序要和它所在的文件夹一起删。'; en = 'You ticked "{0}" but not its folder "{1}". An uninstaller that came with 360 must be deleted together with its folder.' }
    'Plan.VendorUninstallerNeedsInstallRoot.Resolution' = @{ zh = '把文件夹“{0}”也一起勾选，或者取消勾选卸载程序。'; en = 'Also tick the folder "{0}", or untick the uninstaller.' }
    'Plan.VendorUninstallerNeedsInstallRoot.ResolutionUnavailable' = @{ zh = '请取消勾选卸载程序；它所在的文件夹现在不能在这里删除。'; en = 'Untick the uninstaller; its folder cannot be deleted here right now.' }
}
foreach ($w360PartKey in @($script:W360StringsPartB.Keys)) {
    $script:W360Strings[$w360PartKey] = $script:W360StringsPartB[$w360PartKey]
}
Remove-Variable -Name W360StringsPartB -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name w360PartKey -ErrorAction SilentlyContinue

$script:W360StringsPartC = @{
    'Phase.ScanStart'                            = @{ zh = '正在准备…'; en = 'Getting ready...' }
    'Phase.ScanProductFolders'                   = @{ zh = '正在查找 360 软件的文件夹…'; en = 'Looking for 360 program folders...' }
    'Phase.ScanVendorUninstaller'                = @{ zh = '正在查找 360 自带的卸载程序…'; en = 'Looking for uninstallers that came with 360...' }
    'Phase.ScanToolbox'                          = @{ zh = '正在查找工具箱里的 360 部分…'; en = 'Looking for 360 parts inside toolboxes...' }
    'Phase.ScanInstalledPrograms'                = @{ zh = '正在查看已经安装的软件…'; en = 'Looking at installed programs...' }
    'Phase.ScanRegistryResidue'                  = @{ zh = '正在查找 360 留下的设置…'; en = 'Looking for settings left by 360...' }
    'Phase.ScanStartup'                          = @{ zh = '正在查找开机自动运行的 360 程序…'; en = 'Looking for 360 programs that run at startup...' }
    'Phase.ScanScheduledTasks'                   = @{ zh = '正在查找定时自动运行的 360 任务…'; en = 'Looking for 360 tasks that run on a timer...' }
    'Phase.ScanServices'                         = @{ zh = '正在查找在后台运行的 360 服务…'; en = 'Looking for 360 background services...' }
    'Phase.ScanDrivers'                          = @{ zh = '正在查找 360 的系统驱动…'; en = 'Looking for 360 system drivers...' }
    'Phase.ScanProcesses'                        = @{ zh = '正在查看正在运行的程序…'; en = 'Looking at running programs...' }
    'Phase.ScanOfflineWindows'                   = @{ zh = '正在查看电脑上的其他 Windows 系统…'; en = 'Looking at other Windows installations on this PC...' }
    'Phase.ScanComplete'                         = @{ zh = '检查完了'; en = 'Check finished' }
    'Phase.SavingReport'                         = @{ zh = '正在保存结果…'; en = 'Saving the result...' }
    'Phase.Done'                                 = @{ zh = '已完成'; en = 'Finished' }
    'Phase.VerifyReadingPreviousReport'          = @{ zh = '正在读取上次删除的记录…'; en = 'Reading the record of the last deletion...' }
    'Phase.VerifyCheckingTargets'                = @{ zh = '正在逐个确认上次选的内容…'; en = 'Checking each item selected last time...' }
    'Phase.ValidatingApproval'                   = @{ zh = '正在准备删除…'; en = 'Getting ready to delete...' }
    'Phase.WaitingForElevation'                  = @{ zh = 'Windows 弹出了一个窗口，请点“是”继续。点“否”就不会删除任何东西。'; en = 'Windows asks for permission. Click "Yes" to continue. If you click "No", nothing is deleted.' }
    'Phase.ElevationCancelled'                   = @{ zh = '你点了“否”，没有删除任何东西'; en = 'You clicked "No", so nothing was deleted' }
    'Phase.ElevationFailed'                      = @{ zh = 'Windows 弹出窗口这一步出了问题'; en = 'Something went wrong at the Windows prompt' }
    'Phase.ReadingOutcome'                       = @{ zh = '正在整理删除结果…'; en = 'Collecting the deletion result...' }
    'Phase.ElevatedStarted'                      = @{ zh = '已经开始删除'; en = 'Deleting has started' }
    'Phase.RescanBeforeRemoval'                  = @{ zh = '删除前再确认一遍…'; en = 'Checking once more before deleting...' }
    'Phase.ResolvingSelection'                   = @{ zh = '正在核对你选的内容…'; en = 'Matching the items you selected...' }
    'Phase.Preflight'                            = @{ zh = '删除前的安全检查…'; en = 'Safety checks before deleting...' }
    'Phase.VendorUninstaller'                    = @{ zh = '正在运行 360 自带的卸载程序…'; en = 'Running the uninstaller that came with 360...' }
    'Phase.RemovingServices'                     = @{ zh = '正在删除 360 的后台服务…'; en = 'Deleting 360 background services...' }
    'Phase.RemovingTasks'                        = @{ zh = '正在删除 360 的定时任务…'; en = 'Deleting 360 timer tasks...' }
    'Phase.StoppingProcesses'                    = @{ zh = '正在关闭 360 的程序…'; en = 'Closing 360 programs...' }
    'Phase.RemovingRegistryValues'               = @{ zh = '正在删除 360 留下的设置…'; en = 'Deleting settings left by 360...' }
    'Phase.RemovingRegistryKeys'                 = @{ zh = '正在删除 360 留下的设置…'; en = 'Deleting settings left by 360...' }
    'Phase.RemovingPaths'                        = @{ zh = '正在删除文件…'; en = 'Deleting files...' }
    'Phase.RetryingLockedPaths'                  = @{ zh = '有些文件正在使用，正在重试…'; en = 'Some files are in use; trying again...' }
    'Phase.MeasuringResults'                     = @{ zh = '正在统计…'; en = 'Counting...' }
    'Phase.RescanAfterRemoval'                   = @{ zh = '删除后再检查一遍有没有删干净…'; en = 'Checking again after deleting...' }
    'Phase.Error'                                = @{ zh = '出错了，已经停止'; en = 'An error occurred and it stopped' }
    'Phase.Unknown'                              = @{ zh = '正在处理…'; en = 'Working...' }

    'Scan.Cancelled.Headline'                    = @{ zh = '检查已停止'; en = 'Check stopped' }
    'Scan.Cancelled.Detail'                      = @{ zh = '检查没有做完，结果不能用。没有删除任何东西。'; en = 'The check did not finish, so its result cannot be used. Nothing was deleted.' }
    'Scan.Failed.Headline'                       = @{ zh = '出了点问题'; en = 'Something went wrong' }
    'Scan.Failed.ExitCode'                       = @{ zh = '检查没能正常完成（错误代码 {0}），结果不能用。没有删除任何东西。可以重新检查电脑；一直这样的话，请点“获取帮助”。'; en = 'The check did not end normally (error code {0}), so its result cannot be used. Nothing was deleted. You can check the PC again; if this keeps happening, click "Get help".' }
    'Scan.Failed.NoReport'                       = @{ zh = '检查结束了，但没有保存下结果，结果不能用。没有删除任何东西。可以重新检查电脑。'; en = 'The check ended without saving a result, so there is nothing to show. Nothing was deleted. You can check the PC again.' }
    'Scan.Invalid.Headline'                      = @{ zh = '出了点问题'; en = 'Something went wrong' }
    'Scan.Invalid.Detail'                        = @{ zh = '检查结果读不出来或者内容不对，不能用。没有删除任何东西。请重新检查电脑。'; en = 'The check result could not be read or is not in the expected format, so it cannot be used. Nothing was deleted. Please check the PC again.' }
    'Scan.NoMatches.Headline'                    = @{ zh = '没有找到 360 的内容'; en = 'No 360 content was found' }
    'Scan.NoMatches.Detail'                      = @{ zh = '电脑上没有发现本工具认识的 360 软件。'; en = 'Nothing on this PC looks like the 360 software this tool knows.' }
    'Scan.NoMatchesIncomplete.Headline'          = @{ zh = '没有找到 360 的内容，但有些地方没检查完'; en = 'No 360 content was found, but some places were not fully checked' }
    'Scan.NoMatchesIncomplete.Detail'            = @{ zh = '结果可能不全。可以过一会儿再检查一次。'; en = 'The result may be incomplete. You can check again a little later.' }
    'Scan.Findings.Headline'                     = @{ zh = '找到 {0} 个可以删除的 360 软件'; en = '360 software found: {0} product(s) have items you can delete' }
    'Scan.Findings.Detail'                       = @{ zh = '勾选要删除的，再点“删除选中的内容”。没勾选的，本工具不会去删。'; en = 'Tick what to delete, then click "Delete selected". The tool does not delete unticked items.' }
    # Replaces the detail while an uninstaller that came with 360 is ticked: unticked parts are then never promised.
    'Scan.Findings.DetailVendor'                 = @{ zh = '勾选要删除的，再点“删除选中的内容”。你选了 360 自带的卸载程序，同一个软件里没勾选的部分也可能被它删掉。'; en = 'Tick what to delete, then click "Delete selected". The 360 uninstaller you ticked may also remove unticked parts of its product.' }
    'Scan.FindingsKeepOnly.Headline'             = @{ zh = '找到了一些 360 相关的内容，但都不删除'; en = 'Some 360-related items were found, but none of them will be deleted' }
    'Scan.FindingsKeepOnly.Detail'               = @{ zh = '原因写在每一行后面。可以直接关闭。'; en = 'The reason is shown on each row. You can simply close the window.' }

    'Coverage.ScheduledTasks'                    = @{ zh = '定时自动运行的任务'; en = 'Tasks that run on a timer' }
    'Coverage.Services'                          = @{ zh = '后台服务'; en = 'Background services' }
    'Coverage.Processes'                         = @{ zh = '正在运行的程序'; en = 'Running programs' }
    'Coverage.InstalledPrograms'                 = @{ zh = '已经安装的软件'; en = 'Installed programs' }
    'Coverage.ProductEvidence'                   = @{ zh = '360 软件的文件信息'; en = 'File details of 360 software' }
    'Coverage.Drivers'                           = @{ zh = '系统驱动'; en = 'System drivers' }
    'Coverage.TargetProbe'                       = @{ zh = '上次选的某一项'; en = 'An item selected last time' }
    'Coverage.ImmediateRescan'                   = @{ zh = '删除后的再次检查'; en = 'The check right after deleting' }
    'Coverage.Other'                             = @{ zh = '其他地方（{0}）'; en = 'Other place ({0})' }
    'Coverage.IssueText'                         = @{ zh = '{0}没检查完'; en = '{0}: not fully checked' }

    'Remove.NotStarted.Headline'                 = @{ zh = '没有删除任何东西'; en = 'Nothing was deleted' }
    'Remove.NotStarted.Cancelled'                = @{ zh = '你在 Windows 弹出的窗口里点了“否”。'; en = 'You clicked "No" when Windows asked for permission.' }
    'Remove.NotStarted.Error'                    = @{ zh = '删除没能开始。原因：{0}'; en = 'The deletion could not start. Reason: {0}' }
    'Remove.NotStarted.NoReason'                 = @{ zh = '删除程序提前结束了（错误代码 {0}）'; en = 'the deletion program ended early (error code {0})' }
    'Remove.Unknown.Headline'                    = @{ zh = '不确定有没有删干净'; en = 'Not sure everything was deleted' }
    'Remove.Unknown.NoReport'                    = @{ zh = '没有拿到删除结果，不能当作已经删掉。'; en = 'No deletion result was received, so do not treat anything as deleted.' }
    'Remove.Unknown.RescanBlocked'               = @{ zh = '删除后没能再检查一遍，不知道现在还剩什么，不能当作已经删干净。'; en = 'The check after deleting could not finish, so it is not known what is left. Do not treat this as fully deleted.' }
    'Remove.Unknown.SelectedUnknown'             = @{ zh = '有 {0} 项没法确认有没有删掉，不能当作已经删掉。'; en = '{0} selected item(s) could not be confirmed as deleted, so do not treat them as deleted.' }
    'Remove.Completed.Headline'                  = @{ zh = '删除完成'; en = 'Deletion complete' }
    'Remove.Completed.Detail'                    = @{ zh = '你选的 {0} 项都删掉了。你没选的，本工具没有动。'; en = 'All {0} item(s) you selected were deleted. The tool did not touch anything you did not select.' }
    'Remove.Completed.PreservedAffected'         = @{ zh = '你选的都删掉了。另外有 {0} 项你没选的内容，删完后没法确认还在不在，可能被 360 自带的卸载程序一起删掉了。'; en = 'Everything you selected was deleted. {0} item(s) you did not select could not be confirmed as still there afterwards; the uninstaller that came with 360 may have removed them too.' }
    'Remove.Completed.PreservedUnconfirmed'      = @{ zh = '你选的都删掉了。另外有 {0} 项你没选的内容，删完后没法确认还在不在。'; en = 'Everything you selected was deleted. {0} item(s) you did not select could not be confirmed as still there afterwards.' }
    'Remove.Completed.VendorRan'                 = @{ zh = '你选的都删掉了。因为运行了 360 自带的卸载程序，同一个软件里你没选的部分可能也被删掉了。'; en = 'Everything you selected was deleted. Because the uninstaller that came with 360 ran, parts of the same product that you did not select may have been removed too.' }
    'Remove.NeedsRestart.Headline'               = @{ zh = '还差一步：请重启电脑'; en = 'One more step: restart the PC' }
    'Remove.NeedsRestart.Detail'                 = @{ zh = '有些东西正在使用，要重启电脑后才能删掉。'; en = 'Some items are in use and can only be deleted after a restart.' }
    'Remove.Partial.Headline'                    = @{ zh = '有些没删掉'; en = 'Some items were not deleted' }
    'Remove.Partial.Detail'                      = @{ zh = '有些内容没删掉，原因在下面。'; en = 'Some items were not deleted; the reasons are below.' }
    'Remove.Partial.ExitCode'                    = @{ zh = '删除程序没有正常结束（错误代码 {0}），不能确定全部删掉了。'; en = 'The deletion program did not end normally (error code {0}), so it is not certain that everything was deleted.' }
    'Remove.Next.Restart'                        = @{ zh = '先保存好正在做的事，手动重启电脑，然后打开本工具点“{0}”。本工具不会自动重启。'; en = 'Save your work, restart the PC yourself, then open this tool and click "{0}". The tool never restarts the PC by itself.' }
    'Remove.Next.CompletedVerify'                = @{ zh = '可以关闭了。建议找个方便的时候重启电脑，再打开本工具点“{0}”，确认删干净了。本工具不会自动重启。'; en = 'You can close the tool now. When convenient, restart the PC, open this tool and click "{0}" to make sure everything is gone. The tool never restarts the PC by itself.' }
    'Remove.Next.Partial'                        = @{ zh = '先重启电脑，再打开本工具点“{0}”；还是不行的话，点“{1}”。'; en = 'Restart the PC, open this tool and click "{0}"; if that does not help, click "{1}".' }
    'Remove.Next.Unknown'                        = @{ zh = '请重启电脑后打开本工具，点“{0}”。'; en = 'Restart the PC, open this tool and click "{0}".' }
    'Remove.Next.NotStarted'                     = @{ zh = '可以重新检查电脑，或者直接关闭。'; en = 'You can check the PC again or just close the tool.' }
    'Remove.Next.RestartRescan'                  = @{ zh = '请重启电脑后再打开本工具，重新检查一遍电脑。'; en = 'Restart the PC, then open this tool and check the PC again.' }

    'Action.RunVendorUninstaller'                = @{ zh = '运行厂商卸载程序'; en = 'Run vendor uninstaller' }
    'Action.PostVendorPathPreflight'             = @{ zh = '卸载后安全复查'; en = 'Safety check after uninstaller' }
    'Action.DeleteService'                       = @{ zh = '删除系统服务'; en = 'Delete service' }
    'Action.DeleteTask'                          = @{ zh = '删除计划任务'; en = 'Delete scheduled task' }
    'Action.StopProcess'                         = @{ zh = '结束程序'; en = 'Close program' }
    'Action.DeleteRegistryValue'                 = @{ zh = '删除注册表值'; en = 'Delete registry value' }
    'Action.DeleteRegistryKey'                   = @{ zh = '删除注册表项'; en = 'Delete registry key' }
    'Action.DeletePath'                          = @{ zh = '删除文件或文件夹'; en = 'Delete file or folder' }
    'Action.StopModuleHolder'                    = @{ zh = '结束占用文件的程序'; en = 'Close program using the files' }
    'Action.DeletePathRetry'                     = @{ zh = '重试删除'; en = 'Retry delete' }
    'Action.RepairPathAcl'                       = @{ zh = '修复访问权限'; en = 'Repair access permissions' }
    'Action.DeletePathForceRetry'                = @{ zh = '修复权限后再次删除'; en = 'Delete again after permission repair' }
    'Action.VerifyPathRemoval'                   = @{ zh = '确认是否已删除'; en = 'Confirm deletion' }
    'Action.MeasureRemoval'                      = @{ zh = '统计删除结果'; en = 'Count deletion result' }
    'Action.RestartExplorer'                     = @{ zh = '重新启动资源管理器'; en = 'Restart File Explorer' }
    'Action.Other'                               = @{ zh = '其他操作（{0}）'; en = 'Other action ({0})' }
    'Result.Success'                             = @{ zh = '成功'; en = 'Succeeded' }
    'Result.Failed'                              = @{ zh = '失败'; en = 'Failed' }
    'Result.Skipped'                             = @{ zh = '已跳过'; en = 'Skipped' }
    'Result.Pending'                             = @{ zh = '未完成或无法确认'; en = 'Pending or unconfirmed' }
    'Result.PendingRemoval'                      = @{ zh = '等待重启后删除'; en = 'Waiting for restart' }
    'Result.RetryRequired'                       = @{ zh = '需要重试'; en = 'Needs retry' }
    'Result.AlreadyAbsent'                       = @{ zh = '已经不存在'; en = 'Already gone' }
    'Result.Started'                             = @{ zh = '已启动'; en = 'Started' }
    'Result.Other'                               = @{ zh = '其他结果（{0}）'; en = 'Other result ({0})' }
    'RemoveReason.AccessDenied'                  = @{ zh = 'Windows 不让删除（可能被 360 的自我保护挡住了）'; en = 'Windows would not allow it (360 self-protection may be blocking it)' }
    'RemoveReason.DeleteFailed'                  = @{ zh = '没删掉'; en = 'It could not be deleted' }
    'RemoveReason.ReparsePoint'                  = @{ zh = '里面有指向别的地方的特殊文件夹，为了安全没有删除'; en = 'It contains a special folder that points somewhere else, so for safety it was not deleted' }
    'RemoveReason.UnknownInspectionError'        = @{ zh = '没法安全地检查这里，所以没有删除'; en = 'This place could not be checked safely, so it was not deleted' }
    'RemoveReason.VendorUninstallerPending'      = @{ zh = '360 自带的卸载程序还没运行完，或者不知道结果'; en = 'The uninstaller that came with 360 has not finished, or its result is not known' }
    'RemoveReason.PostVendorIdentityUnreadable'  = @{ zh = '卸载程序运行后，没法再确认这一项还是原来那个'; en = 'After the uninstaller ran, it could not be confirmed that this is still the same item' }
    'RemoveReason.PostVendorIdentityChanged'     = @{ zh = '卸载程序运行后这一项变了，为了安全没有删除'; en = 'This item changed after the uninstaller ran, so for safety it was not deleted' }
    'RemoveReason.AclRepairFailed'               = @{ zh = '试过了，Windows 还是不让删除'; en = 'Windows still would not allow deleting it' }
    'RemoveReason.Locked'                        = @{ zh = '文件正在被别的程序使用，重启电脑后再检查一次'; en = 'Files are in use by another program; restart the PC and check again' }
    'RemoveReason.ServicePendingRemoval'         = @{ zh = '要重启电脑后才能删完'; en = 'It will be fully deleted only after a restart' }
    'RemoveReason.ProcessAlreadyExited'          = @{ zh = '这个程序已经自己关掉了，不用再关'; en = 'The program had already closed by itself; nothing to close' }
    'RemoveReason.VendorUninstallerFailed'       = @{ zh = '360 自带的卸载程序没有成功'; en = 'The uninstaller that came with 360 did not succeed' }
    'RemoveReason.GenericFailed'                 = @{ zh = '没有成功'; en = 'It did not succeed' }
    'RemoveReason.GenericSkipped'                = @{ zh = '为了安全，这一步跳过了'; en = 'This step was skipped for safety' }
    'RemoveReason.GenericPending'                = @{ zh = '还没做完，或者不知道结果'; en = 'It has not finished, or the result is not known' }
    'RemoveReason.GenericRetry'                  = @{ zh = '需要再试一次，但没有得到最后结果'; en = 'It needed another try, but no final result was recorded' }
    'Stats.Selected'                             = @{ zh = '选了要删除的'; en = 'Selected for deletion' }
    'Stats.Preserved'                            = @{ zh = '你保留的'; en = 'Kept by you' }
    'Stats.FilesRemoved'                         = @{ zh = '删掉的文件'; en = 'Files deleted' }
    'Stats.DirectoriesRemoved'                   = @{ zh = '删掉的文件夹'; en = 'Folders deleted' }
    'Stats.LogicalSize'                          = @{ zh = '文件逻辑大小'; en = 'Logical file size' }
    'Stats.LogicalSizeNote'                      = @{ zh = '不等于磁盘实际增加的可用空间'; en = 'not the same as the free disk space gained' }
    'Stats.MinimumNote'                          = @{ zh = '有些地方没法统计，下面是最少的数字'; en = 'Some places could not be measured; these are minimum values' }
    'Stats.ServicesRemoved'                      = @{ zh = '删掉的后台服务'; en = 'Background services deleted' }
    'Stats.ServicesPendingRemoval'               = @{ zh = '重启后才能删掉的后台服务'; en = 'Background services deleted only after a restart' }
    'Stats.ScheduledTasksRemoved'                = @{ zh = '删掉的定时任务'; en = 'Timer tasks deleted' }
    'Stats.RegistryItemsRemoved'                 = @{ zh = '删掉的 360 设置'; en = 'Settings left by 360 deleted' }
    'Stats.ProcessesStopped'                     = @{ zh = '关掉的程序'; en = 'Programs closed' }
    'Stats.VendorUninstallersSucceeded'          = @{ zh = '运行成功的 360 自带卸载程序'; en = 'Uninstallers that came with 360 and succeeded' }
    'Stats.SkippedActions'                       = @{ zh = '跳过的步骤'; en = 'Skipped steps' }
    'Stats.FailedActions'                        = @{ zh = '没成功的步骤'; en = 'Failed steps' }
    'Stats.PendingActions'                       = @{ zh = '没做完的步骤'; en = 'Unfinished steps' }
}
foreach ($w360PartKey in @($script:W360StringsPartC.Keys)) {
    $script:W360Strings[$w360PartKey] = $script:W360StringsPartC[$w360PartKey]
}
Remove-Variable -Name W360StringsPartC -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name w360PartKey -ErrorAction SilentlyContinue

$script:W360StringsPartD = @{
    'Verify.Cancelled.Headline'                  = @{ zh = '检查已停止'; en = 'Check stopped' }
    'Verify.Cancelled.Detail'                    = @{ zh = '检查没有做完，结果不能用。没有删除任何东西。'; en = 'The check did not finish, so its result cannot be used. Nothing was deleted.' }
    'Verify.Failed.Headline'                     = @{ zh = '出了点问题'; en = 'Something went wrong' }
    'Verify.Failed.ExitCode'                     = @{ zh = '检查没能正常完成（错误代码 {0}），结果不能用。没有删除任何东西。'; en = 'The check did not end normally (error code {0}), so its result cannot be used. Nothing was deleted.' }
    'Verify.Failed.NoReport'                     = @{ zh = '检查结束了，但没有保存下结果，结果不能用。没有删除任何东西。'; en = 'The check ended without saving a result, so there is nothing to show. Nothing was deleted.' }
    'Verify.Invalid.Headline'                    = @{ zh = '出了点问题'; en = 'Something went wrong' }
    'Verify.Invalid.Detail'                      = @{ zh = '检查结果读不出来或者内容不对，不能用。没有删除任何东西。'; en = 'The check result could not be read or is not in the expected format, so it cannot be used. Nothing was deleted.' }
    'Verify.TaskCompleted.Headline'              = @{ zh = '上次选的都删干净了'; en = 'Everything selected last time is gone' }
    'Verify.TaskCompletedKeptAttention.Headline' = @{ zh = '上次选的都删干净了，但你保留的内容需要检查'; en = 'Selected items are gone; check the items you kept' }
    'Verify.TaskCompletedIncomplete.Headline'    = @{ zh = '上次选的都删干净了，但有些地方没检查完'; en = 'Everything selected last time is gone, but some places were not fully checked' }
    'Verify.TaskCompleted.Detail'                = @{ zh = '上次选的 {0} 项都确认删掉了。'; en = 'All {0} item(s) selected last time are confirmed gone.' }
    'Verify.TaskCompleted.PreservedKept'         = @{ zh = '你保留的内容还在，这是正常的。'; en = 'The items you kept are still there. That is expected.' }
    'Verify.TaskCompleted.PreservedChanged'      = @{ zh = '你保留的内容里有 {0} 项发生了变化。'; en = '{0} kept item(s) changed.' }
    'Verify.TaskCompleted.PreservedUnknown'      = @{ zh = '你保留的内容里有 {0} 项暂时无法确认是否还在。'; en = '{0} kept item(s) could not be checked.' }
    'Verify.TaskCompleted.PreservedGone'         = @{ zh = '你保留的内容里有 {0} 项不见了，可能被 360 自带的卸载程序一起删了。如果还需要，请重新安装。'; en = '{0} item(s) you kept are gone; the uninstaller that came with 360 may have removed them. If you still need them, install them again.' }
    'Verify.TaskCompleted.PreservedGonePlain'    = @{ zh = '你保留的内容里有 {0} 项不见了。如果还需要，请重新安装。'; en = '{0} item(s) you kept are gone. If you still need them, install them again.' }
    'Verify.TaskCompletedWithNew.Headline'       = @{ zh = '上次选的都删干净了，但又找到 {0} 项新的 360 内容'; en = 'Everything selected last time is gone, but {0} new 360 item(s) were found' }
    'Verify.TaskCompletedWithNew.Detail'         = @{ zh = '新找到的内容没有删除，删不删由你决定。'; en = 'The newly found items were not deleted; you decide whether to delete them.' }
    'Verify.TaskRemaining.Headline'              = @{ zh = '还有 {0} 项没删掉'; en = '{0} item(s) were not deleted' }
    'Verify.TaskRemaining.Detail'                = @{ zh = '上次选的内容里，有 {0} 项还在或者有变化。'; en = '{0} of the items selected last time are still there or have changed.' }
    'Verify.TaskUnknown.Headline'                = @{ zh = '有 {0} 项没法确认有没有删掉'; en = '{0} item(s) could not be confirmed as deleted' }
    'Verify.TaskUnknown.HeadlineNoCount'         = @{ zh = '上次选的看起来都删掉了，但这次检查没做完整'; en = 'Everything selected last time looks gone, but this check was not complete' }
    'Verify.TaskUnknown.Detail'                  = @{ zh = '这次检查没能确认结果，不能当作已经删干净。'; en = 'This check could not confirm the result, so do not treat it as fully deleted.' }
    'Verify.TaskUnknown.DetailNoCount'           = @{ zh = '这次检查没有正常做完，不能当作已经删干净。'; en = 'This check did not finish normally, so do not treat it as fully deleted.' }
    'Verify.TaskUnavailable.Headline'            = @{ zh = '上次删除的记录用不了，已经重新检查了一遍电脑'; en = 'The record of the last deletion cannot be used, so the whole PC was checked again' }
    'Verify.TaskUnavailable.Detail'              = @{ zh = '{0}，所以没法逐项确认上次选的内容。这次检查的结果：{1}。'; en = '{0}, so the items selected last time cannot be confirmed one by one. Result of this check: {1}.' }
    'Verify.GlobalClean.Headline'                = @{ zh = '没有找到还需要处理的 360 内容'; en = 'No 360 content that needs attention was found' }
    'Verify.GlobalClean.Detail'                  = @{ zh = '电脑上没有发现本工具认识的 360 内容。'; en = 'Nothing on this PC looks like the 360 content this tool knows.' }
    # Nothing can be deleted, but items that are never deleted (for example a still installed program) remain.
    'Verify.GlobalKeptOnly.Headline'             = @{ zh = '没有找到可以删除的 360 内容，但还有 {0} 项不删除的内容'; en = 'Nothing that can be deleted was found, but {0} 360 item(s) that are not deleted remain' }
    'Verify.GlobalKeptOnly.Detail'               = @{ zh = '比如还装着、要先正常卸载的软件。原因写在每一行后面。'; en = 'For example, software that is still installed and needs a normal uninstall first. The reason is shown on each row.' }
    'Verify.GlobalRemaining.Headline'            = @{ zh = '电脑上还有 {0} 项 360 的内容'; en = '{0} 360 item(s) are still on this PC' }
    'Verify.GlobalRemaining.Detail'              = @{ zh = '这次检查没有删除任何东西。'; en = 'This check did not delete anything.' }
    'Verify.GlobalIncomplete.Headline'           = @{ zh = '没有找到还需要处理的 360 内容，但有些地方没检查完'; en = 'No 360 content that needs attention was found, but some places were not fully checked' }
    'Verify.GlobalIncomplete.Detail'             = @{ zh = '结果可能不全。'; en = 'The result may be incomplete.' }
    'Verify.Section.SelectedRemaining'           = @{ zh = '没删掉'; en = 'Not deleted' }
    'Verify.Section.Preserved'                   = @{ zh = '你保留的'; en = 'Kept by you' }
    'Verify.Section.PreservedGone'               = @{ zh = '你保留的，但不见了'; en = 'Kept by you, but gone' }
    'Verify.Section.NewOrChanged'                = @{ zh = '新找到的或有变化的'; en = 'Newly found or changed' }
    'Verify.Section.Unknown'                     = @{ zh = '没法确认或没检查完'; en = 'Could not be confirmed or not fully checked' }
    'Verify.Section.Cleared'                     = @{ zh = '已删掉'; en = 'Deleted' }
    'Verify.Section.CurrentIdentified'           = @{ zh = '现在还有的 360 内容'; en = '360 items still on this PC' }
    'Verify.Section.CurrentKept'                 = @{ zh = '不删除的'; en = "Won't be deleted" }
    'Verify.Next.Done'                           = @{ zh = '可以关闭了。'; en = 'You can close the tool now.' }
    'Verify.Next.KeptGone'                       = @{ zh = '如果还需要不见了的那些内容，请重新安装。'; en = 'If you still need the items that are gone, install them again.' }
    'Verify.Next.KeptUnconfirmed'                = @{ zh = '试试想保留的软件能否正常使用，再点“{0}”；仍不确定时，点“{1}”。'; en = 'Try the software you kept, then click "{0}". Still unsure? Click "{1}".' }
    'Verify.Next.KeptOnly'                       = @{ zh = '可以关闭了。想删除这些的话，先按每一行的说明处理，再重新检查电脑。'; en = 'You can close the tool now. To delete these, first do what each row says, then check the PC again.' }
    'Verify.Next.IncompleteRetry'                = @{ zh = '有些地方没检查完，可以过一会儿再检查一次。'; en = 'Some places were not fully checked; you can check again a little later.' }
    'Verify.Next.RescanDecide'                   = @{ zh = '可以点“{0}”，再决定删不删。'; en = 'You can click "{0}" and then decide whether to delete.' }
    'Verify.Next.RestartIfLocked'                = @{ zh = '重启电脑后，打开本工具点“{0}”；还是删不掉的话，点“{1}”。'; en = 'Restart the PC, open this tool and click "{0}"; if the items still cannot be deleted, click "{1}".' }
    'Verify.Next.RestartAndRetry'                = @{ zh = '重启电脑后，打开本工具点“{0}”；还是不行的话，点“{1}”。'; en = 'Restart the PC, open this tool and click "{0}"; if that does not help, click "{1}".' }
    'Verify.Next.Rescan'                         = @{ zh = '可以点“{0}”，看看现在电脑上还有什么。'; en = 'You can click "{0}" to see what is on the PC now.' }
    'Verify.Next.Retry'                          = @{ zh = '可以再试一次；一直这样的话，点“{0}”。'; en = 'You can try again; if this keeps happening, click "{0}".' }
    'VerifyState.Selected.Absent'                = @{ zh = '已删掉'; en = 'Deleted' }
    'VerifyState.Selected.Remaining'             = @{ zh = '还在'; en = 'Still there' }
    'VerifyState.Selected.Changed'               = @{ zh = '有变化，可能不是原来那个了'; en = 'Changed; it may not be the same item' }
    'VerifyState.Selected.Unknown'               = @{ zh = '没法确认'; en = 'Could not be confirmed' }
    'VerifyState.Preserved.Present'              = @{ zh = '还在'; en = 'Still there' }
    'VerifyState.Preserved.Absent'               = @{ zh = '不见了（可能被 360 自带的卸载程序一起删了）'; en = 'Gone (the uninstaller that came with 360 may have removed it)' }
    'VerifyState.Preserved.AbsentPlain'          = @{ zh = '不见了'; en = 'Gone' }
    'VerifyState.Preserved.Unknown'              = @{ zh = '没法确认'; en = 'Could not be confirmed' }
    'VerifyState.Preserved.Changed'              = @{ zh = '有变化，可能不是原来那个了'; en = 'Changed; it may not be the same item' }
    'VerifyState.New.New'                        = @{ zh = '新找到的'; en = 'Newly found' }
    'VerifyState.Current.Confirmed'              = @{ zh = '还在'; en = 'Still there' }
    'VerifyState.Coverage'                       = @{ zh = '没检查完'; en = 'Not fully checked' }
    'VerifyState.Other'                          = @{ zh = '没法确认（{0}）'; en = 'Could not be confirmed ({0})' }
    'Verify.CoverageKind'                        = @{ zh = '没检查完的地方'; en = 'Place not fully checked' }
    'DetailCode.ProbeAbsent'                     = @{ zh = '直接查看过，确认它已经不在了。'; en = 'A direct look confirmed that it is gone.' }
    'DetailCode.DetectedSameIdentity'            = @{ zh = '这次检查又找到了它，和上次的是同一个。'; en = 'This check found it again, and it is the same item as last time.' }
    'DetailCode.PresentNotDetected'              = @{ zh = '它还在，只是这次没有被认成 360 的内容。'; en = 'It is still there; it just was not recognised as 360 content this time.' }
    'DetailCode.DetectedDifferentIdentity'       = @{ zh = '同一个位置还有东西，但和上次的不一样了。'; en = 'Something is still at the same place, but it is different from last time.' }
    'DetailCode.PathPresentNotDetected'          = @{ zh = '这个位置还在，但现在看起来已经不像 360 的内容了。'; en = 'The location still exists, but it no longer looks like 360 content.' }
    'DetailCode.ProbeUnreadable'                 = @{ zh = '检查时读不到它，没法确认它还在不在。'; en = 'It could not be read during the check, so it is not known whether it is still there.' }
    'DetailCode.QueryFailed'                     = @{ zh = '没能读到结果，没法确认它还在不在。'; en = 'No answer could be read, so it is not known whether it is still there.' }
    'DetailCode.NewFinding'                      = @{ zh = '上次没有记录，这次新找到的。'; en = 'This was not recorded last time and was newly found now.' }
    'Unavailable.RemoveReportMissing'            = @{ zh = '找不到上次删除的记录'; en = 'The record of the last deletion was not found' }
    'Unavailable.RemoveReportUnreadable'         = @{ zh = '上次删除的记录读不出来'; en = 'The record of the last deletion could not be read' }
    'Unavailable.RemoveReportInvalid'            = @{ zh = '上次删除的记录不完整'; en = 'The record of the last deletion is incomplete' }
    'Unavailable.RemoveReportIncompatible'       = @{ zh = '上次删除的记录来自不兼容的版本'; en = 'The record of the last deletion comes from an incompatible version' }
    'Unavailable.SelectionNotRecorded'           = @{ zh = '上次删除的记录里没有写你选了哪些'; en = 'The record of the last deletion does not say which items you selected' }
    'Unavailable.DifferentUser'                  = @{ zh = '上次是另一个 Windows 用户删除的'; en = 'The last deletion was done by another Windows user' }
    'Unavailable.Other'                          = @{ zh = '上次删除的记录用不了'; en = 'The record of the last deletion cannot be used' }

    'Help.Title'                                 = @{ zh = 'Windows 360 清理工具 · 问题信息'; en = 'Windows 360 Cleaner - problem information' }
    'Help.Disclaimer.Redacted'                   = @{ zh = '已经尽量去掉了用户名、文件夹名等隐私，但可能有遗漏，发给别人之前请逐行看一遍。'; en = 'User names, folder names and other private details were removed as far as possible, but something may have been missed. Read every line before you send it to anyone.' }
    'Help.Disclaimer.NotApproval'                = @{ zh = '这段文字只用来找人帮忙，不能用来删除任何东西，也不代表你同意删除。'; en = 'This text is only for asking for help. It can never be used to delete anything and does not mean that you agreed to delete anything.' }
    'Help.Disclaimer.ReportKept'                 = @{ zh = '原来的记录文件还在你的电脑上，没有被改动。'; en = 'The original record files are still on your PC and were not changed.' }
    'Help.Disclaimer.NoUpload'                   = @{ zh = '本工具不会自动上传任何内容。'; en = 'This tool never uploads anything automatically.' }
    'Help.ToolVersion'                           = @{ zh = '工具版本：{0}'; en = 'Tool version: {0}' }
    'Help.Windows'                               = @{ zh = 'Windows：{0}（版本 {1}，内部版本号 {2}，{3}）'; en = 'Windows: {0} (version {1}, build {2}, {3})' }
    'Help.Bitness64'                             = @{ zh = '64 位'; en = '64-bit' }
    'Help.Bitness32'                             = @{ zh = '32 位'; en = '32-bit' }
    'Help.PowerShell'                            = @{ zh = 'PowerShell：{0}'; en = 'PowerShell: {0}' }
    'Help.UiCulture'                             = @{ zh = '界面语言：{0}'; en = 'UI culture: {0}' }
    'Help.Stage'                                 = @{ zh = '在哪一步：{0}'; en = 'Step: {0}' }
    'Help.Stage.Scan'                            = @{ zh = '检查电脑'; en = 'Checking the PC' }
    'Help.Stage.Remove'                          = @{ zh = '删除'; en = 'Deleting' }
    'Help.Stage.Verify'                          = @{ zh = '检查上次删除的结果'; en = 'Checking the last deletion' }
    'Help.Stage.Error'                           = @{ zh = '出了意外的问题'; en = 'Something unexpected went wrong' }
    'Help.Outcome'                               = @{ zh = '结果：{0} · {1}'; en = 'Result: {0} - {1}' }
    'Help.OutcomeDetail'                         = @{ zh = '说明：{0}'; en = 'Detail: {0}' }
    'Help.NoOutcome'                             = @{ zh = '结果：没有拿到结果'; en = 'Result: no result was received' }
    'Help.ReportFile'                            = @{ zh = '记录文件名：{0}'; en = 'Record file name: {0}' }
    'Help.CoverageIssues'                        = @{ zh = '没检查完的地方：'; en = 'Places that were not fully checked:' }
    'Help.FindingCounts'                         = @{ zh = '找到的 360 内容：共 {0} 项；可以删除 {1} 项；不删除 {2} 项'; en = "360 items found: {0} in total; {1} can be deleted; {2} won't be deleted" }
    'Help.RemainingFindings'                     = @{ zh = '删除后马上又检查了一遍，还找到的 360 内容（包括你没选、保留下来的）：共 {0} 项'; en = '360 items still found by the check right after deleting (including the ones you did not tick and kept): {0}' }
    'Help.SnapshotFindings'                      = @{ zh = '删除前最后一次检查找到的 360 内容（不代表现在还剩什么）：共 {0} 项'; en = '360 items found by the last check before deleting (not what is left now): {0}' }
    'Help.RemoveStats'                           = @{ zh = '统计：选了 {0} 项，保留 {1} 项；删掉文件 {2} 个、文件夹 {3} 个；没成功的步骤 {4} 个，跳过的步骤 {5} 个，没做完的步骤 {6} 个'; en = 'Numbers: {0} selected, {1} kept; {2} files and {3} folders deleted; {4} failed, {5} skipped and {6} unfinished steps' }
    'Help.Problems'                              = @{ zh = '没删掉、跳过或没做完的：{0} 项'; en = 'Not deleted, skipped or not finished: {0}' }
    'Help.VerifySections'                        = @{ zh = '检查上次删除的结果：已删掉 {0} 项；没删掉 {1} 项；你保留的 {2} 项；你保留的，但不见了 {5} 项；新找到的或有变化的 {3} 项；没法确认或没检查完 {4} 项'; en = 'Last deletion check: deleted {0}; not deleted {1}; kept by you {2}; kept by you, but gone {5}; newly found or changed {3}; could not be confirmed or not fully checked {4}' }
    'Help.ErrorText'                             = @{ zh = '相关错误信息：'; en = 'Related error output:' }
    'Help.StdoutTail'                            = @{ zh = '程序输出（最后几行）：'; en = 'Program output (last lines):' }
    'Redact.UserName'                            = @{ zh = '<用户名>'; en = '<user name>' }
    'Redact.ComputerName'                        = @{ zh = '<计算机名>'; en = '<computer name>' }
    'Redact.Domain'                              = @{ zh = '<域>'; en = '<domain>' }
    'Redact.Sid'                                 = @{ zh = '<已隐藏>'; en = '<hidden>' }
    'Redact.Email'                               = @{ zh = '<邮箱>'; en = '<e-mail>' }
    'Redact.PrivatePath'                         = @{ zh = '<私人路径已隐藏>'; en = '<private path hidden>' }
    'Redact.NetworkPath'                         = @{ zh = '<网络路径已隐藏>'; en = '<network path hidden>' }
    'Redact.Desktop'                             = @{ zh = '<桌面>'; en = '<Desktop>' }
    'Redact.Identifier'                          = @{ zh = '<标识已隐藏>'; en = '<identifier hidden>' }

    'Ui.Home.Title'                              = @{ zh = '上次删除的记录'; en = 'Last deletion' }
    'Ui.Home.TaskTime'                           = @{ zh = '时间：{0}'; en = 'Time: {0}' }
    'Ui.Home.Counts'                             = @{ zh = '上次选了 {0} 项要删除，保留了 {1} 项'; en = '{0} item(s) were selected for deletion last time; {1} were kept' }
    'Ui.Home.Restarted'                          = @{ zh = '电脑已经重启过，可以检查结果了。'; en = 'The PC has restarted since then, so you can check the result now.' }
    'Ui.Home.NotRestarted'                       = @{ zh = '电脑还没有重启。建议先保存好正在做的事，重启电脑后再检查结果。'; en = 'The PC has not restarted yet. Save your work and restart the PC before checking the result.' }
    'Ui.Home.RestartUnknown'                     = @{ zh = '不确定电脑有没有重启过。'; en = 'It is not known whether the PC has restarted since then.' }
    'Ui.Home.NewerUnusable'                      = @{ zh = '之后还有 {0} 次删除没拿到结果（可能是点了“否”，也可能是中途出了问题，不确定删了多少）。想知道电脑上现在还有什么，请点“重新检查电脑”。'; en = 'After that, {0} deletion attempt(s) left no result ("No" may have been clicked, or something went wrong halfway, so it is not known how much was deleted). To see what is on the PC now, click "Check the PC again".' }
    'Ui.Home.ReadOnlyNote'                       = @{ zh = '检查不会删除任何东西。'; en = 'Checking never deletes anything.' }
    'Ui.AlreadyRunning'                          = @{ zh = '本工具已经打开了。'; en = 'The tool is already open.' }
    'Ui.Button.VerifyTask'                       = @{ zh = '检查上次删除的结果'; en = 'Check the last deletion' }
    'Ui.Button.Close'                            = @{ zh = '关闭'; en = 'Close' }
    'Ui.Button.Cancel'                           = @{ zh = '取消'; en = 'Cancel' }
    'Ui.Button.StopCheck'                        = @{ zh = '停止检查'; en = 'Stop checking' }
    'Ui.Button.CoverageDetails'                  = @{ zh = '看看是哪些'; en = 'Show which ones' }
    'Ui.Button.SelectAllDeletable'               = @{ zh = '全选可以删除的'; en = 'Select all deletable' }
    'Ui.Button.ClearSelection'                   = @{ zh = '全部不选'; en = 'Clear all' }
    'Ui.Button.HelpSummary'                      = @{ zh = '获取帮助'; en = 'Get help' }
    'Ui.Button.OpenReportFolder'                 = @{ zh = '打开记录所在文件夹'; en = 'Open the records folder' }
    'Ui.Button.CleanSelected'                    = @{ zh = '删除选中的内容…'; en = 'Delete selected...' }
    'Ui.Button.AddChildren'                      = @{ zh = '把这 {0} 项也选上'; en = 'Select these {0} too' }
    'Ui.Button.BackToEdit'                       = @{ zh = '返回修改'; en = 'Go back and change' }
    'Ui.Button.ConfirmRemove'                    = @{ zh = '删除'; en = 'Delete' }
    'Ui.Button.ViewDetails'                      = @{ zh = '详细信息'; en = 'Details' }
    # The same action as the home page button, so every "click ..." sentence names a button the user can find.
    'Ui.Button.VerifyNow'                        = @{ zh = '检查上次删除的结果'; en = 'Check the last deletion' }
    'Ui.Button.Rescan'                           = @{ zh = '重新检查电脑'; en = 'Check the PC again' }
    'Ui.Button.Copy'                             = @{ zh = '复制'; en = 'Copy' }
    'Ui.Button.SaveText'                         = @{ zh = '保存成文件'; en = 'Save as a file' }
    'Ui.Button.OpenGitHub'                       = @{ zh = '打开求助网页'; en = 'Open the help web page' }
    'Ui.Button.MoreInfo'                         = @{ zh = '更多信息'; en = 'More info' }
    'Ui.Progress.Title.Scan'                     = @{ zh = '正在检查电脑…'; en = 'Checking the PC...' }
    'Ui.Progress.Title.Verify'                   = @{ zh = '正在检查上次删除的结果…'; en = 'Checking the last deletion...' }
    'Ui.Progress.Title.VerifyGlobal'             = @{ zh = '正在检查电脑…'; en = 'Checking the PC...' }
    'Ui.Progress.Title.Remove'                   = @{ zh = '正在删除…'; en = 'Deleting...' }
    # Before Windows allowed the deletion nothing is deleted yet; the page says so instead of "deleting".
    'Ui.Progress.Title.RemovePreparing'          = @{ zh = '正在准备删除…'; en = 'Getting ready to delete...' }
    'Ui.Progress.Title.RemoveWaiting'            = @{ zh = '请在 Windows 弹出的窗口里点“是”'; en = 'Click "Yes" when Windows asks for permission' }
    'Ui.Progress.Elapsed'                        = @{ zh = '已用时间 {0}'; en = 'Time so far: {0}' }
    'Ui.Progress.ReadOnlyNote'                   = @{ zh = '检查不会删除任何东西，可以随时停止。'; en = 'Checking never deletes anything. You can stop at any time.' }
    # Always true, even if progress cannot be read: it never claims that nothing has been deleted so far.
    'Ui.Progress.RemoveBeforeNote'               = @{ zh = '在 Windows 弹出的窗口里点“是”以后，才会开始删除。请不要关闭窗口。'; en = 'Deleting starts only after you click "Yes" when Windows asks for permission. Please do not close the window.' }
    'Ui.Progress.RemoveNote'                     = @{ zh = '正在删除，不能中途停止。请不要关闭窗口，也不要关机。'; en = 'Deleting now. It cannot be stopped halfway. Do not close the window or shut down the PC.' }
    'Ui.Close.BlockedDuringRemove'               = @{ zh = '正在删除，现在不能关闭窗口，也不能中途停止。请等删除结束。'; en = 'Deleting now. The window cannot be closed and the deletion cannot be stopped halfway. Please wait until it finishes.' }
    'Ui.Close.CancelFirst'                       = @{ zh = '检查还没做完。要停止检查并关闭窗口吗？'; en = 'The check has not finished. Stop the check and close the window?' }
    'Ui.Scan.CoverageBanner'                     = @{ zh = '有些地方没检查完，结果可能不全。'; en = 'Some places were not fully checked; the result may be incomplete.' }
    'Ui.Group.Header'                            = @{ zh = '{0} {1}'; en = '{0} {1}' }
    'Ui.Group.CanDelete'                         = @{ zh = '可以删除（{0} 项）'; en = 'Can be deleted ({0})' }
    'Ui.Group.CanDeleteSomeKept'                 = @{ zh = '可以删除（{0} 项），{1} 项不删除'; en = '{0} can be deleted, {1} not' }
    'Ui.Row.WillDelete'                          = @{ zh = '要删除'; en = 'Will be deleted' }
    'Ui.Select.SkippedNote'                      = @{ zh = '有 {0} 项没有帮你选上，比如“{1}”：{2}。'; en = '{0} item(s) were not selected for you, for example "{1}": {2}.' }
    'Ui.Select.SkippedNoteOne'                   = @{ zh = '“{0}”没有帮你选上：{1}。'; en = '"{0}" was not selected for you: {1}.' }
    'Ui.Select.SkipReason.ParentContainsProtectedChild' = @{ zh = '里面有要保留的东西'; en = 'it contains things that must be kept' }
    'Ui.Select.SkipReason.ParentContainsSelectableChild' = @{ zh = '里面还有没勾选的东西'; en = 'it contains things that are not ticked' }
    'Ui.Select.SkipReason.VendorUninstallerNeedsInstallRoot' = @{ zh = '要和它所在的文件夹一起删'; en = 'it must be deleted together with its folder' }
    'Ui.Column.Select'                           = @{ zh = '勾选'; en = 'Select' }
    'Ui.Column.Item'                             = @{ zh = '内容'; en = 'Item' }
    'Ui.Column.Decision'                         = @{ zh = '删不删'; en = 'Delete?' }
    'Ui.Column.Result'                           = @{ zh = '结果'; en = 'Result' }
    'Ui.Detail.Status'                           = @{ zh = '删不删'; en = 'Delete?' }
    'Ui.Detail.Reason'                           = @{ zh = '为什么列出来'; en = 'Why it is listed' }
    'Ui.Detail.Impact'                           = @{ zh = '删除后会怎样'; en = 'What deleting it does' }
    'Ui.Detail.Product'                          = @{ zh = '属于哪个软件'; en = 'Product' }
    'Ui.Detail.Technical'                        = @{ zh = '技术信息'; en = 'Technical details' }
    'Ui.Detail.ItemWhat'                         = @{ zh = '{0}：{1}，属于“{2}”。'; en = '{0}: {1}, part of "{2}".' }
    'Ui.Detail.GroupWhat'                        = @{ zh = '{0}：{1}'; en = '{0}: {1}' }
    'Ui.Detail.AfterDelete'                      = @{ zh = '删除后：{0}'; en = 'After deleting: {0}' }
    'Ui.Detail.WhyKept'                          = @{ zh = '为什么不删除：{0}'; en = 'Why it is kept: {0}' }
    'Ui.Detail.GroupCounts'                      = @{ zh = '可以删除 {0} 项，不删除 {1} 项。'; en = '{0} can be deleted, {1} kept.' }
    'Ui.Scan.SelectionCounter'                   = @{ zh = '已选 {0} 项要删除。'; en = '{0} item(s) selected for deletion.' }
    'Ui.Scan.TooMany'                            = @{ zh = '已选 {0} 项，一次最多删除 {1} 项，请分几次删除。'; en = '{0} item(s) selected, but at most {1} can be deleted at a time. Please delete them in several rounds.' }
    'Ui.Plan.Title'                              = @{ zh = '还需要调整一下'; en = 'A few changes are needed' }
    'Ui.Confirm.Title'                           = @{ zh = '确定要删除吗？'; en = 'Delete these items?' }
    'Ui.Confirm.DeleteTitle'                     = @{ zh = '要删除的（{0} 项）：'; en = 'To delete ({0}):' }
    'Ui.Confirm.GroupLine'                       = @{ zh = '{0}（{1} 项）'; en = '{0} ({1})' }
    'Ui.Confirm.AfterTitle'                      = @{ zh = '删除后：'; en = 'After deleting:' }
    'Ui.Confirm.KeptTitle'                       = @{ zh = '会保留的：'; en = 'Kept:' }
    # With an uninstaller that came with 360 selected, its own product is never promised to be kept; other products
    # are only promised not to be deleted by this tool.
    'Ui.Confirm.KeptSameProduct'                 = @{ zh = '同一个软件里你没选的（360 自带的卸载程序可能也会删掉）：'; en = 'Parts of the same product you did not select (the uninstaller that came with 360 may remove them too):' }
    'Ui.Confirm.KeptOther'                       = @{ zh = '你没选的（本工具不会删）：'; en = 'Not selected (this tool does not delete them):' }
    'Ui.Confirm.NotSelected'                     = @{ zh = '{0}（你没选）'; en = '{0} (not selected)' }
    'Ui.Confirm.SkippedThisTime'                 = @{ zh = '{0}（这次不能单独删）'; en = '{0} (cannot be deleted on its own this time)' }
    'Ui.Confirm.KeptReason'                      = @{ zh = '{0}（{1}）'; en = '{0} ({1})' }
    'Ui.Confirm.RunUninstaller'                  = @{ zh = '运行{0}'; en = 'Run: {0}' }
    'Ui.Confirm.ImpactLine'                      = @{ zh = '{0}：{1}'; en = '{0}: {1}' }
    'Ui.Confirm.NameMore'                        = @{ zh = '{0}等 {1} 项'; en = '{0} and others ({1})' }
    'Ui.Confirm.PermanentDelete'                 = @{ zh = '删除后不能恢复，也不会放进回收站。'; en = 'Deleted items cannot be recovered and do not go to the Recycle Bin.' }
    'Ui.Confirm.VendorWarning'                   = @{ zh = '你选的内容里有 360 自带的卸载程序，它可能会把同一个软件里你没选的部分也一起删掉。'; en = 'Your selection includes an uninstaller that came with 360. It may also remove parts of the same product that you did not select.' }
    'Ui.Confirm.CloseApps'                       = @{ zh = '删除前请先关闭 360 的软件，需要的书签等资料请先备份。'; en = 'Close the 360 programs first, and back up bookmarks or other data you need.' }
    'Ui.Confirm.Uac'                             = @{ zh = '点“删除”后，Windows 会弹出窗口问你是否允许，请点“是”。'; en = 'After you click "Delete", Windows asks for permission. Click "Yes".' }
    'Ui.Error.ReportChanged'                     = @{ zh = '检查结果在你选择的时候被改动了，请重新检查电脑。没有删除任何东西。'; en = 'The check result changed while you were choosing. Please check the PC again. Nothing was deleted.' }
    'Ui.Remove.Section.Stats'                    = @{ zh = '统计'; en = 'Statistics' }
    'Ui.Remove.Counts'                           = @{ zh = '删掉 {0} 项 · 没删掉 {1} 项 · 不确定 {2} 项'; en = '{0} deleted · {1} not deleted · {2} not sure' }
    'Ui.Remove.ProblemLine'                      = @{ zh = '“{0}”：{1}'; en = '"{0}": {1}' }
    'Ui.Remove.ProblemLineCount'                 = @{ zh = '“{0}”：{1}（{2} 处）'; en = '"{0}": {1} ({2} places)' }
    'Ui.Remove.MoreProblems'                     = @{ zh = '还有 {0} 项，点“详细信息”查看。'; en = '{0} more; click "Details" to see them.' }
    'Ui.NextSteps'                               = @{ zh = '接下来：{0}'; en = 'Next: {0}' }
    'Ui.Help.Title'                              = @{ zh = '获取帮助'; en = 'Get help' }
    'Ui.Help.Privacy'                            = @{ zh = '下面是问题信息，已经尽量去掉了用户名、文件夹名等隐私，但可能有遗漏，发给别人之前请逐行看一遍。本工具不会自动上传。'; en = 'Below is the problem information. User names, folder names and other private details were removed as far as possible, but something may have been missed, so read every line before you send it to anyone. This tool never uploads anything automatically.' }
    'Ui.Help.Saved'                              = @{ zh = '已保存到：{0}'; en = 'Saved to: {0}' }
}
foreach ($w360PartKey in @($script:W360StringsPartD.Keys)) {
    $script:W360Strings[$w360PartKey] = $script:W360StringsPartD[$w360PartKey]
}
Remove-Variable -Name W360StringsPartD -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name w360PartKey -ErrorAction SilentlyContinue

$script:W360FindingNameKeys = @{
    '360 Program Files'                                     = 'Name.ProgramFiles360'
    '360 Program Files (x86)'                               = 'Name.ProgramFilesX86360'
    '360 ProgramData'                                       = 'Name.ProgramData360'
    '360Safe ProgramData'                                   = 'Name.ProgramData360Safe'
    '360Chrome browser application'                         = 'Name.ChromeApplication'
    '360Chrome browser profile'                             = 'Name.ChromeProfile'
    '360ChromeX browser application'                        = 'Name.ChromeXApplication'
    '360ChromeX browser profile'                            = 'Name.ChromeXProfile'
    'Duohui screen saver'                                   = 'Name.DuohuiInstall'
    '360se6 browser application'                            = 'Name.Se6Application'
    '360se6 browser profile'                                = 'Name.Se6Profile'
    '360browser legacy profile'                             = 'Name.LegacyBrowserProfile'
    '360 Software Manager UI kernel'                        = 'Name.SoftMgrUiKernel'
    '360Safe'                                               = 'Name.RoamingSafe'
    '360GameAssistant'                                      = 'Name.GameAssistant'
    '360huabao'                                             = 'Name.Huabao'
    '360DrvMgrScrSaver'                                     = 'Name.DriverMasterScreenSaver'
    'GreenCore'                                             = 'Name.GreenCore'
    'GreenCore7z'                                           = 'Name.GreenCore7z'
    'Duohui temporary package'                              = 'Name.DuohuiTemp'
    'Huabao temporary package'                              = 'Name.HuabaoTemp'
    '360 Game Assistant temporary files'                    = 'Name.GameAssistantTemp'
    '360 unpack temporary files'                            = 'Name.UnpackTemp'
    'Duohui vendor uninstaller'                             = 'Name.DuohuiVendorUninstaller'
    '360 temporary package'                                 = 'Name.TempCab'
    '360 SoftMgr inside Aolande/Huajun winToolBox'          = 'Name.ToolboxSoftMgr'
    'Ambiguous SoftMgr inside winToolBox'                   = 'Name.ToolboxAmbiguousSoftMgr'
    '360-signed component inside third-party winToolBox'    = 'Name.ToolboxSignedComponent'
    'Aolande/Huajun winToolBox mixed bundle'                = 'Name.ToolboxBundle'
    'winToolBox updater linked to confirmed SoftMgr bundle' = 'Name.ToolboxUpdater'
    'Roaming SoftMgr cache'                                 = 'Name.RoamingSoftMgr'
    'Program Files SoftMgr'                                 = 'Name.ProgramFilesSoftMgr'
    'Duohui registry residue'                               = 'Name.DuohuiRegistryResidue'
    'Offline Windows 360 path'                              = 'Name.OfflineWindowsPath'
    'Offline user 360 path'                                 = 'Name.OfflineUserPath'
}

# Every English Reason emitted by Get-360Findings is mapped here. Suffixes appended by the detector
# (missing evidence, preserved browser profile, missing identity fingerprint) are stripped first.
$script:W360ReasonRules = @(
    @{ Pattern = '^Exact vendor product directory with local 360/Qihoo file evidence\.$'; Key = 'Reason.VendorProductDirectory'; Group = 0 }
    @{ Pattern = '^Exact vendor data directory paired with local 360/Qihoo file evidence\.$'; Key = 'Reason.VendorDataDirectory'; Group = 0 }
    @{ Pattern = '^Exact 360Safe data directory paired with local 360/Qihoo file evidence\.$'; Key = 'Reason.SafeDataDirectory'; Group = 0 }
    @{ Pattern = '^Exact 360Chrome Application directory with local 360/Qihoo file evidence\.$'; Key = 'Reason.ChromeApplication'; Group = 0 }
    @{ Pattern = '^Exact 360ChromeX Application directory with local 360/Qihoo file evidence\.$'; Key = 'Reason.ChromeXApplication'; Group = 0 }
    @{ Pattern = '^Exact 360se6 Application directory with local 360/Qihoo file evidence\.$'; Key = 'Reason.Se6Application'; Group = 0 }
    @{ Pattern = '^360Chrome User Data can contain bookmarks, history, saved sessions, and other user data\.$'; Key = 'Reason.ChromeProfile'; Group = 0 }
    @{ Pattern = '^360ChromeX User Data can contain bookmarks, history, saved sessions, and other user data\.$'; Key = 'Reason.ChromeXProfile'; Group = 0 }
    @{ Pattern = '^360se6 User Data can contain bookmarks, history, saved sessions, and other user data\.$'; Key = 'Reason.Se6Profile'; Group = 0 }
    @{ Pattern = '^Legacy browser profiles can contain bookmarks, history, saved sessions, and other user data\.$'; Key = 'Reason.LegacyBrowserProfile'; Group = 0 }
    @{ Pattern = '^Known duohuipingbao installation path\.$'; Key = 'Reason.DuohuiInstallPath'; Group = 0 }
    @{ Pattern = '^Exact secoresdk 360se6 product directory with local 360/Qihoo file evidence\.$'; Key = 'Reason.SoftMgrUiKernel'; Group = 0 }
    @{ Pattern = '^Exact current-user path with local 360/Qihoo file evidence\.$'; Key = 'Reason.CurrentUserPath'; Group = 0 }
    @{ Pattern = '^GreenCore cache requires a 360greencore marker\.$'; Key = 'Reason.GreenCoreCache'; Group = 0 }
    @{ Pattern = '^GreenCore archive cache requires a 360 marker\.$'; Key = 'Reason.GreenCoreArchive'; Group = 0 }
    @{ Pattern = '^Known duohuipingbao staging path\.$'; Key = 'Reason.DuohuiStaging'; Group = 0 }
    @{ Pattern = '^Known Huabao installer staging path\.$'; Key = 'Reason.HuabaoStaging'; Group = 0 }
    @{ Pattern = '^Exact temporary component path with local 360/Qihoo file evidence\.$'; Key = 'Reason.TemporaryComponent'; Group = 0 }
    @{ Pattern = '^Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co\., Ltd\. signature and Duohui/Huabao metadata\. SHA-256:\s*[0-9A-Fa-f]*$'; Key = 'Reason.VendorUninstallerConfirmed'; Group = 0 }
    @{ Pattern = '^The exact Duohui uninstaller path exists, but its SHA-256 identity could not be read safely\.\s*The exact uninstaller path chain was not proven safe\.$'; Key = 'Reason.VendorUninstallerPathUnsafe'; Group = 0 }
    @{ Pattern = '^The exact Duohui uninstaller path exists, but its SHA-256 identity could not be read safely\.(?:\s.*)?$'; Key = 'Reason.VendorUninstallerHashUnreadable'; Group = 0 }
    @{ Pattern = '^The exact uninstaller path chain was not proven safe\.$'; Key = 'Reason.VendorUninstallerPathChainUnsafe'; Group = 0 }
    @{ Pattern = '^The exact Duohui uninstaller path exists, but it lacks a confirmed dhpingbao root, the required valid publisher signature and Duohui/Huabao metadata, or a valid SHA-256 identity\.$'; Key = 'Reason.VendorUninstallerNotTrusted'; Group = 0 }
    @{ Pattern = '^Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion\.$'; Key = 'Reason.TempCabName'; Group = 0 }
    @{ Pattern = '^SoftMgr subtree contains 360-signed or 360-identified executable/DLL evidence; winToolBox itself is third-party\.$'; Key = 'Reason.ToolboxSoftMgr'; Group = 0 }
    @{ Pattern = '^Name matched SoftMgr but deterministic 360 markers were not found\.$'; Key = 'Reason.ToolboxAmbiguousSoftMgr'; Group = 0 }
    @{ Pattern = '^File is signed or identified as a 360/Qihoo component\. Signer:\s*(.*)$'; Key = 'Reason.ToolboxSignedComponent'; Group = 1 }
    @{ Pattern = '^Third-party toolbox contains confirmed 360 components\. Do not remove the entire toolbox without separate approval\.$'; Key = 'Reason.ToolboxBundle'; Group = 0 }
    @{ Pattern = '^Exact third-party updater associated with a locally confirmed 360 SoftMgr/download chain\.$'; Key = 'Reason.ToolboxUpdater'; Group = 0 }
    @{ Pattern = '^Paired with confirmed 360 SoftMgr evidence\.$'; Key = 'Reason.RoamingSoftMgrConfirmed'; Group = 0 }
    @{ Pattern = '^SoftMgr name without enough local 360 evidence\.$'; Key = 'Reason.RoamingSoftMgrUnconfirmed'; Group = 0 }
    @{ Pattern = '^360 product metadata or DLL markers found\.$'; Key = 'Reason.ProgramFilesSoftMgrConfirmed'; Group = 0 }
    @{ Pattern = '^Ambiguous SoftMgr directory without sufficient markers\.$'; Key = 'Reason.ProgramFilesSoftMgrUnconfirmed'; Group = 0 }
    @{ Pattern = '^360-family uninstall record has stale file references and no live install location or vendor uninstaller\.$'; Key = 'Reason.OrphanUninstallRecord'; Group = 0 }
    @{ Pattern = '^360-family product record has a live vendor uninstaller; run it before registry cleanup\.$'; Key = 'Reason.LiveVendorUninstaller'; Group = 0 }
    @{ Pattern = '^360-family product record has a live install location; inspect it and prefer its vendor uninstaller first\.$'; Key = 'Reason.LiveInstallLocation'; Group = 0 }
    @{ Pattern = '^There is not enough evidence to prove this uninstall record is orphaned; inspect its file references before registry cleanup\.$'; Key = 'Reason.UninstallRecordNotProven'; Group = 0 }
    @{ Pattern = '^Exact Duohui residue paired with the proven orphan HKCU duohuipingbao uninstall record\.$'; Key = 'Reason.DuohuiResidueConfirmed'; Group = 0 }
    @{ Pattern = '^Exact Duohui residue found without a proven orphan HKCU duohuipingbao uninstall record; review only\.$'; Key = 'Reason.DuohuiResidueUnconfirmed'; Group = 0 }
    @{ Pattern = '^Startup executable is under confirmed target:\s*(.+)$'; Key = 'Reason.StartupUnderTarget'; Group = 1 }
    @{ Pattern = '^Startup name/path matched a 360-family marker, but its executable was not under a confirmed target\.$'; Key = 'Reason.StartupNameOnly'; Group = 0 }
    @{ Pattern = '^Screen saver setting points under a confirmed target\.$'; Key = 'Reason.ScreenSaverUnderTarget'; Group = 0 }
    @{ Pattern = '^Task action points under an exact confirmed target\.$'; Key = 'Reason.TaskUnderTarget'; Group = 0 }
    @{ Pattern = '^Task name matched, but its action was not under a confirmed target\.$'; Key = 'Reason.TaskNameOnly'; Group = 0 }
    @{ Pattern = '^Service executable is a confirmed target or confirmed mixed-bundle updater\.$'; Key = 'Reason.ServiceUnderTarget'; Group = 0 }
    @{ Pattern = '^Service executable is under a confirmed mixed winToolBox bundle, but this sibling toolbox service is not approved for removal\.$'; Key = 'Reason.ServiceToolboxSibling'; Group = 0 }
    @{ Pattern = '^Service name/path matched, but its executable was not under a confirmed target\.$'; Key = 'Reason.ServiceNameOnly'; Group = 0 }
    @{ Pattern = '^System driver requires vendor-uninstaller and driver-package review; never auto-delete\.$'; Key = 'Reason.Driver'; Group = 0 }
    @{ Pattern = '^Executable path under confirmed target:\s*(.+)$'; Key = 'Reason.ProcessUnderTarget'; Group = 1 }
    @{ Pattern = '^Found in another Windows installation; the bundled script is permanently scan-only for offline roots\.$'; Key = 'Reason.OfflineWindows'; Group = 0 }
    @{ Pattern = '^Found under another Windows user profile; scan-only\.$'; Key = 'Reason.OfflineUser'; Group = 0 }
)

# Plain-language policy of the main window (pages, confirmation dialog, selection dialog). The Chinese words are
# never shown there; the English words are avoided in the English main-window texts. Tests use both lists.
$script:W360MainUiBannedWords = @(
    '识别', '扫描', '复检', '报告', '授权', '提权', '注册表', '计划任务', '系统服务', '厂商', '只读', '逻辑大小', '证据',
    '身份', '标识', '规则', '匹配', '退出代码', '进程', '全局', 'Confidence', 'SelectionId', 'ReviewOnly', '状态码',
    # Item names, descriptions and reasons say folder, part and downloaded files instead of these.
    '目录', '组件', '缓存', '权限', '路径', '签名', '残留', '查询'
)
$script:W360MainUiBannedEnglishWords = @(
    'Confidence', 'SelectionId', 'ReviewOnly', 'read-only', 'report', 'verification', 'elevation', 'registry',
    'scheduled task', 'vendor'
)
# Text keys that are shown only in secondary windows (More info, Details, Get help, the fatal error box) and may
# therefore keep technical words. Every other key is main-window text and must follow the policy above.
$script:W360SecondaryTextKeyRules = @(
    @{ Pattern = '^Tech\.'; Reason = 'Raw field labels of the More info window.' }
    @{ Pattern = '^Reason\.'; Reason = 'Detector reasons, shown only in the More info window.' }
    # The other Help.* lines and the Get help window texts use the plain words, so only these technical lines stay here.
    @{ Pattern = '^Help\.(ToolVersion|Windows|Bitness32|Bitness64|PowerShell|UiCulture|ErrorText|StdoutTail)$'; Reason = 'Technical lines of the help text: versions, system details and raw program output.' }
    @{ Pattern = '^Redact\.'; Reason = 'Placeholders that replace private paths and identifiers inside the help text.' }
    @{ Pattern = '^Stats\.'; Reason = 'Statistics of the Details window.' }
    @{ Pattern = '^Action\.'; Reason = 'Action names of the action log in the Details window.' }
    @{ Pattern = '^Result\.'; Reason = 'Action results of the action log in the Details window.' }
    @{ Pattern = '^Gui\.Fatal$'; Reason = 'Fatal error message box with the technical reason.' }
    @{ Pattern = '^Gui\.Remove\.Log'; Reason = 'Title and intro of the action log in the Details window.' }
    @{ Pattern = '^Gui\.Column\.'; Reason = 'Column headers of the Details window grids.' }
    @{ Pattern = '^Gui\.Detail\.'; Reason = 'Field labels of the More info window.' }
    @{ Pattern = '^Gui\.Error\.TechnicalTitle$'; Reason = 'Title of the technical text window.' }
    @{ Pattern = '^Gui\.Error\.NoTechnical$'; Reason = 'Placeholder of the technical text window.' }
    @{ Pattern = '^Gui\.Scan\.CoverageTitle$'; Reason = 'Title of the not-fully-checked list window.' }
    @{ Pattern = '^Gui\.Scan\.CoverageIntro$'; Reason = 'Intro of the not-fully-checked list window.' }
)

function Get-W360UiLanguage {
    if ($script:W360UiLanguage -ceq 'zh' -or $script:W360UiLanguage -ceq 'en') {
        return [string]$script:W360UiLanguage
    }
    try {
        if ([Globalization.CultureInfo]::CurrentUICulture.Name -match '^zh') { return 'zh' }
    }
    catch {}
    return 'en'
}

function Set-W360UiLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('zh', 'en')]
        [string]$Language
    )

    $script:W360UiLanguage = $Language.ToLowerInvariant()
}

function Get-W360Text {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][AllowEmptyCollection()][object[]]$Arguments
    )

    if (-not $script:W360Strings.ContainsKey($Key)) {
        throw "Unknown UI text key: $Key"
    }
    $entry = $script:W360Strings[$Key]
    $template = [string]$entry[(Get-W360UiLanguage)]
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $template, $Arguments)
    }
    return $template
}

function Test-W360TextKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return $script:W360Strings.ContainsKey($Key)
}

function Add-W360Text {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Chinese,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$English
    )

    if ($script:W360Strings.ContainsKey($Key)) {
        $existing = $script:W360Strings[$Key]
        if ([string]$existing['zh'] -ceq $Chinese -and [string]$existing['en'] -ceq $English) { return }
        throw "UI text key already exists with different text: $Key"
    }
    $script:W360Strings[$Key] = @{ zh = $Chinese; en = $English }
}

# Returns the banned main-window words contained in Text (Chinese list for zh, English list for en, case-insensitive).
function Get-W360MainUiBannedWords {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('zh', 'en')][string]$Language = 'zh'
    )

    if ([string]::IsNullOrEmpty($Text)) { return [string[]]@() }
    $words = if ($Language -eq 'en') { $script:W360MainUiBannedEnglishWords } else { $script:W360MainUiBannedWords }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($word in $words) {
        if ($Text.IndexOf([string]$word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found.Add([string]$word) }
    }
    return [string[]]$found.ToArray()
}

# Returns why a text key may keep technical words (secondary windows only), or '' for main-window text.
function Get-W360SecondaryTextKeyReason {
    param([AllowNull()][AllowEmptyString()][string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    foreach ($rule in $script:W360SecondaryTextKeyRules) {
        if ($Key -cmatch [string]$rule.Pattern) { return [string]$rule.Reason }
    }
    return ''
}

function Get-W360PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-W360StringProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-W360PropertyValue -Object $Object -Name $Name
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Test-W360HasProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

# True when the property is missing or JSON null. An empty array is a present value.
function Test-W360NullProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $true }
    if ($Object -is [System.Collections.IDictionary]) {
        return (-not $Object.Contains($Name) -or $null -eq $Object[$Name])
    }
    $property = $Object.PSObject.Properties[$Name]
    return ($null -eq $property -or $null -eq $property.Value)
}

# Emits the non-null items of an array-valued property. Callers wrap the call in @().
function Get-W360ArrayProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return }
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return }
        $value = $Object[$Name]
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return }
        $value = $property.Value
    }
    Get-W360Items -Value $value
}

function Get-W360Items {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
    if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or
        -not ($Value -is [System.Collections.IEnumerable])) {
        return $Value
    }
    foreach ($item in $Value) {
        if ($null -ne $item) { $item }
    }
}

function ConvertTo-W360Bool {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return $Value.Trim() -ieq 'true' }
    try { return [bool]$Value }
    catch { return $false }
}

function ConvertTo-W360NullableInt64 {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    $parsed = [long]0
    if ([long]::TryParse(([string]$Value).Trim(), [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function ConvertTo-W360Int64 {
    param([AllowNull()][object]$Value)

    $parsed = ConvertTo-W360NullableInt64 -Value $Value
    if ($null -eq $parsed) { return [long]0 }
    return [long]$parsed
}

function Test-W360IsProgressMarkerLine {
    param([AllowNull()][string]$Line)
    return ($null -ne $Line -and $Line.StartsWith('W360-PROGRESS|', [StringComparison]::Ordinal))
}

function Get-W360TailLines {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Lines,
        [int]$Count = 30
    )

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-W360Items -Value $Lines)) {
        $text = ([string]$line).TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text) -or (Test-W360IsProgressMarkerLine -Line $text)) { continue }
        $kept.Add($text)
    }
    $start = [Math]::Max(0, $kept.Count - $Count)
    for ($index = $start; $index -lt $kept.Count; $index++) { $kept[$index] }
}

function Get-W360ErrorText {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$StderrLines,
        [AllowNull()][AllowEmptyCollection()][object[]]$StdoutLines,
        [switch]$IncludeStdout
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $errorLines = @(Get-W360TailLines -Lines $StderrLines -Count 30)
    if ($errorLines.Count -gt 0) { $parts.Add(($errorLines -join "`r`n")) }
    if ($IncludeStdout) {
        $outputLines = @(Get-W360TailLines -Lines $StdoutLines -Count 30)
        if ($outputLines.Count -gt 0) {
            $parts.Add(((Get-W360Text -Key 'Help.StdoutTail') + "`r`n" + ($outputLines -join "`r`n")))
        }
    }
    return ($parts.ToArray() -join "`r`n`r`n")
}

function Test-W360FindingSelectable {
    param([AllowNull()][object]$Finding)

    if ($null -eq $Finding) { return $false }
    $removalType = Get-W360StringProperty -Object $Finding -Name 'RemovalType'
    return ((Get-W360StringProperty -Object $Finding -Name 'Confidence') -eq 'Confirmed' -and
        -not (ConvertTo-W360Bool (Get-W360PropertyValue -Object $Finding -Name 'Offline')) -and
        -not [string]::IsNullOrWhiteSpace($removalType) -and $removalType -ne 'None' -and
        (Get-W360StringProperty -Object $Finding -Name 'SelectionId') -match '^[0-9A-Fa-f]{64}$')
}

function Get-W360FindingSelectionId {
    param([AllowNull()][object]$Finding)

    $id = (Get-W360StringProperty -Object $Finding -Name 'SelectionId').Trim()
    if ($id -match '^[0-9A-Fa-f]{64}$') { return $id.ToUpperInvariant() }
    return ''
}

function Get-W360ProductKey {
    param([AllowNull()][string]$ProductKey)

    if (-not [string]::IsNullOrWhiteSpace($ProductKey)) {
        foreach ($known in $script:W360ProductOrder) {
            if ($known.Equals($ProductKey.Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $known }
        }
    }
    return 'Unattributed'
}

function Get-W360ProductInfo {
    param([AllowNull()][AllowEmptyString()][string]$ProductKey)

    $key = Get-W360ProductKey -ProductKey $ProductKey
    return [pscustomobject]@{
        Key         = $key
        DisplayName = Get-W360Text -Key ('Product.' + $key + '.Name')
        Description = Get-W360Text -Key ('Product.' + $key + '.Description')
        Impact      = Get-W360Text -Key ('Product.' + $key + '.Impact')
    }
}

function Test-W360TargetLooksLikeFile {
    param([AllowNull()][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }
    try { $extension = [IO.Path]::GetExtension($Target.Trim().TrimEnd('\', '/')) }
    catch { return $false }
    return @(
        '.exe', '.dll', '.cab', '.sys', '.scr', '.msi', '.zip', '.7z', '.rar', '.dat', '.ini', '.log', '.tmp',
        '.json', '.xml', '.txt', '.db', '.lnk', '.bin', '.bat', '.cmd', '.ps1', '.vbs', '.ocx', '.cpl', '.drv',
        '.inf', '.cat', '.mui', '.pdb', '.ico', '.png', '.jpg'
    ) -contains ([string]$extension).ToLowerInvariant()
}

function Test-W360FindingIsBrowserProfile {
    param([AllowNull()][object]$Finding)

    $name = Get-W360StringProperty -Object $Finding -Name 'Name'
    $target = (Get-W360StringProperty -Object $Finding -Name 'Target').TrimEnd('\', '/')
    return ($name -match '(?i)profile$' -or $target -match '(?i)[\\/]User Data$' -or
        $name -ieq '360browser legacy profile')
}

function Get-W360FindingKindText {
    param([AllowNull()][object]$Finding)

    $kind = Get-W360StringProperty -Object $Finding -Name 'Kind'
    switch ($kind) {
        'Path' {
            if (Test-W360TargetLooksLikeFile -Target (Get-W360StringProperty -Object $Finding -Name 'Target')) {
                return (Get-W360Text -Key 'Kind.File')
            }
            return (Get-W360Text -Key 'Kind.Folder')
        }
        'OfflinePath' { return (Get-W360Text -Key 'Kind.OfflinePath') }
        'VendorUninstaller' { return (Get-W360Text -Key 'Kind.VendorUninstaller') }
        'InstalledProduct' { return (Get-W360Text -Key 'Kind.InstalledProduct') }
        'RegistryResidue' { return (Get-W360Text -Key 'Kind.RegistryResidue') }
        'Startup' { return (Get-W360Text -Key 'Kind.Startup') }
        'ScreenSaver' { return (Get-W360Text -Key 'Kind.ScreenSaver') }
        'ScheduledTask' { return (Get-W360Text -Key 'Kind.ScheduledTask') }
        'Service' { return (Get-W360Text -Key 'Kind.Service') }
        'Driver' { return (Get-W360Text -Key 'Kind.Driver') }
        'Process' { return (Get-W360Text -Key 'Kind.Process') }
        'Bundle' { return (Get-W360Text -Key 'Kind.Bundle') }
    }
    $shown = if ([string]::IsNullOrWhiteSpace($kind)) { Get-W360Text -Key 'Common.Unknown' } else { $kind }
    return (Get-W360Text -Key 'Kind.Unknown' -Arguments @($shown))
}

# Selectable says whether the core would accept the item at all (Test-W360FindingSelectable). Deletable says whether it
# can be ticked in this check result: with -Effective (Get-W360EffectiveDeletableIds of the whole check) an item outside
# the effectively deletable set reads as "won't delete" with its reason. -Effective only ever narrows.
function Get-W360FindingStatus {
    param(
        [AllowNull()][object]$Finding,
        [AllowNull()][object]$Effective
    )

    $code = 'NotRemovable'
    $selectable = Test-W360FindingSelectable -Finding $Finding
    $deletable = [bool]$selectable
    $kind = Get-W360StringProperty -Object $Finding -Name 'Kind'
    $confidence = Get-W360StringProperty -Object $Finding -Name 'Confidence'
    $removalType = Get-W360StringProperty -Object $Finding -Name 'RemovalType'
    $reason = Get-W360StringProperty -Object $Finding -Name 'Reason'
    $offline = ConvertTo-W360Bool (Get-W360PropertyValue -Object $Finding -Name 'Offline')

    if ($selectable) {
        $code = 'AwaitingChoice'
        if ($null -ne $Effective -and -not (Test-W360FindingDeletable -Finding $Finding -Effective $Effective)) {
            $deletable = $false
            $code = Get-W360EffectiveKeepCode -Effective $Effective -SelectionId (Get-W360FindingSelectionId -Finding $Finding)
        }
    }
    elseif ($offline -or $kind -eq 'OfflinePath') { $code = 'OfflineReportOnly' }
    elseif (Test-W360FindingIsBrowserProfile -Finding $Finding) { $code = 'PersonalDataKept' }
    elseif ($kind -eq 'Driver') { $code = 'DriverReviewOnly' }
    elseif ($kind -eq 'Bundle') { $code = 'BundleKept' }
    elseif ($reason -match '(?i)identity fingerprint could not be captured') { $code = 'IdentityUnconfirmed' }
    elseif ($confidence -eq 'Confirmed' -and -not [string]::IsNullOrWhiteSpace($removalType) -and
        $removalType -ne 'None') { $code = 'MissingSelectionId' }
    elseif ($confidence -eq 'ReviewOnly' -and $kind -eq 'InstalledProduct' -and
        $reason -match '(?i)has a live (vendor uninstaller|install location)') { $code = 'StillInstalled' }
    elseif ($confidence -eq 'ReviewOnly') { $code = 'InsufficientEvidence' }

    return [pscustomobject]@{
        Code        = $code
        Text        = Get-W360Text -Key ('Status.' + $code + '.Text')
        Explanation = Get-W360Text -Key ('Status.' + $code + '.Explanation')
        Selectable  = [bool]$selectable
        Deletable   = [bool]$deletable
    }
}

function Get-W360FindingDisplayName {
    param([AllowNull()][object]$Finding)

    $kind = Get-W360StringProperty -Object $Finding -Name 'Kind'
    $name = Get-W360StringProperty -Object $Finding -Name 'Name'
    $target = Get-W360StringProperty -Object $Finding -Name 'Target'

    switch ($kind) {
        'InstalledProduct' {
            if ([string]::IsNullOrWhiteSpace($name)) { return (Get-W360Text -Key 'Name.InstalledProductUnnamed') }
            return (Get-W360Text -Key 'Name.InstalledProductRecord' -Arguments @($name.Trim()))
        }
        'ScreenSaver' { return (Get-W360Text -Key 'Name.ScreenSaverSetting') }
        { $_ -in @('Startup', 'ScheduledTask', 'Service', 'Process', 'Driver') } {
            # A raw name such as "ZhuDongFangYu" says nothing to a beginner, so the plain kind comes first.
            $kindText = Get-W360FindingKindText -Finding $Finding
            $rawName = if ([string]::IsNullOrWhiteSpace($name)) { $target } else { $name }
            if ($kind -eq 'Process') {
                # "360tray.exe (4242)" is shown as "360tray": the process ID and the extension mean nothing here.
                $rawName = ([regex]::Replace([string]$rawName, '\s*\(\d+\)\s*$', '') -replace '(?i)\.exe$', '').Trim()
                if ($rawName -match '^\d+$') { $rawName = '' }
            }
            if ([string]::IsNullOrWhiteSpace($rawName)) { return $kindText }
            return (Get-W360Text -Key 'Name.WithKind' -Arguments @($kindText, $rawName.Trim()))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($name) -and $script:W360FindingNameKeys.ContainsKey($name.Trim())) {
        $key = [string]$script:W360FindingNameKeys[$name.Trim()]
        if ($key -eq 'Name.ToolboxSignedComponent') {
            $leaf = ''
            try { $leaf = [IO.Path]::GetFileName($target.TrimEnd('\', '/')) }
            catch { $leaf = $target }
            return (Get-W360Text -Key $key -Arguments @($leaf))
        }
        return (Get-W360Text -Key $key)
    }
    # A raw location is never a name on the main window; the More info window shows it.
    if ([string]::IsNullOrWhiteSpace($name)) { return (Get-W360FindingKindText -Finding $Finding) }
    return $name
}

function ConvertFrom-W360ReasonString {
    param([AllowNull()][string]$Reason)

    if ([string]::IsNullOrWhiteSpace($Reason)) { return $null }
    $text = $Reason.Trim()
    $identityMissing = $false
    $evidenceMissing = $false
    $profilePreserved = $false

    $identityMatch = [regex]::Match($text,
        '(?is)\s*Exact identity fingerprint could not be captured; automatic removal is disabled\..*$')
    if ($identityMatch.Success) {
        $identityMissing = $true
        $text = $text.Substring(0, $identityMatch.Index).TrimEnd()
    }
    $evidenceMatch = [regex]::Match($text, '(?i)\s*Expected product evidence was not found\.$')
    if ($evidenceMatch.Success) {
        $evidenceMissing = $true
        $text = $text.Substring(0, $evidenceMatch.Index).TrimEnd()
    }
    $profileMatch = [regex]::Match($text,
        '(?i)\s*Preserved by default; use the separate browser-profile opt-in only after backing up needed data\.$')
    if ($profileMatch.Success) {
        $profilePreserved = $true
        $text = $text.Substring(0, $profileMatch.Index).TrimEnd()
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $baseText = $null
    foreach ($rule in $script:W360ReasonRules) {
        $match = [regex]::Match($text, [string]$rule.Pattern)
        if (-not $match.Success) { continue }
        if ([int]$rule.Group -gt 0) {
            $baseText = Get-W360Text -Key ([string]$rule.Key) -Arguments @($match.Groups[[int]$rule.Group].Value.Trim())
        }
        else {
            $baseText = Get-W360Text -Key ([string]$rule.Key)
        }
        break
    }
    if ($null -eq $baseText) { return $null }

    # These detector sentences describe the evidence rule itself, so the clause must follow the real result.
    $evidenceRuleKeys = @(
        'Reason.VendorProductDirectory', 'Reason.VendorDataDirectory', 'Reason.SafeDataDirectory',
        'Reason.ChromeApplication', 'Reason.ChromeXApplication', 'Reason.Se6Application',
        'Reason.SoftMgrUiKernel', 'Reason.CurrentUserPath', 'Reason.TemporaryComponent'
    )
    $evidenceHandled = $false
    if ($evidenceRuleKeys -contains [string]$rule.Key) {
        $clauseKey = if ($evidenceMissing) { 'Reason.Evidence.Missing' } else { 'Reason.Evidence.Found' }
        $baseText = $baseText + (Get-W360Text -Key $clauseKey)
        $evidenceHandled = $true
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($baseText)
    if ($evidenceMissing -and -not $evidenceHandled) { $parts.Add((Get-W360Text -Key 'Reason.Suffix.EvidenceMissing')) }
    if ($profilePreserved) { $parts.Add((Get-W360Text -Key 'Reason.Suffix.ProfilePreserved')) }
    if ($identityMissing) { $parts.Add((Get-W360Text -Key 'Reason.Suffix.IdentityMissing')) }
    return ($parts.ToArray() -join (Get-W360Text -Key 'Common.SentenceSeparator'))
}

function Get-W360ReasonText {
    param([AllowNull()][object]$Finding)

    $reason = Get-W360StringProperty -Object $Finding -Name 'Reason'
    if ([string]::IsNullOrWhiteSpace($reason)) { return (Get-W360Text -Key 'Reason.None') }
    $mapped = ConvertFrom-W360ReasonString -Reason $reason
    if ($null -eq $mapped) { return (Get-W360Text -Key 'Reason.Unmapped' -Arguments @($reason.Trim())) }
    return $mapped
}

function Get-W360ImpactText {
    param(
        [AllowNull()][object]$Finding,
        # The effectively deletable set of the whole check (Get-W360EffectiveDeletableIds); items outside it are kept.
        [AllowNull()][object]$Effective
    )

    $kept = -not (Test-W360FindingSelectable -Finding $Finding)
    if (-not $kept -and $null -ne $Effective) { $kept = -not (Test-W360FindingDeletable -Finding $Finding -Effective $Effective) }
    if ($kept) {
        $status = Get-W360FindingStatus -Finding $Finding -Effective $Effective
        switch ($status.Code) {
            'PersonalDataKept' { return (Get-W360Text -Key 'Impact.Kept.Profile') }
            'OfflineReportOnly' { return (Get-W360Text -Key 'Impact.Kept.Offline') }
            'DriverReviewOnly' { return (Get-W360Text -Key 'Impact.Kept.Driver') }
            'BundleKept' { return (Get-W360Text -Key 'Impact.Kept.Bundle') }
        }
        return (Get-W360Text -Key 'Impact.Kept')
    }

    $kind = Get-W360StringProperty -Object $Finding -Name 'Kind'
    $name = Get-W360StringProperty -Object $Finding -Name 'Name'
    $target = Get-W360StringProperty -Object $Finding -Name 'Target'
    $removalType = Get-W360StringProperty -Object $Finding -Name 'RemovalType'
    $productKey = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $Finding -Name 'ProductKey')

    if ($kind -eq 'VendorUninstaller' -or $removalType -eq 'VendorUninstaller') { return (Get-W360Text -Key 'Impact.VendorUninstaller') }
    switch ($kind) {
        'Service' { return (Get-W360Text -Key 'Impact.Service') }
        'ScheduledTask' { return (Get-W360Text -Key 'Impact.Task') }
        'Startup' { return (Get-W360Text -Key 'Impact.Startup') }
        'ScreenSaver' { return (Get-W360Text -Key 'Impact.ScreenSaver') }
        'Process' { return (Get-W360Text -Key 'Impact.Process') }
        'InstalledProduct' { return (Get-W360Text -Key 'Impact.OrphanUninstallRecord') }
        'RegistryResidue' { return (Get-W360Text -Key 'Impact.RegistryResidue') }
    }
    if ($removalType -eq 'Path') {
        if (Test-W360FindingIsBrowserProfile -Finding $Finding) { return (Get-W360Text -Key 'Impact.BrowserProfile') }
        if ($name -match '(?i)browser application$') { return (Get-W360Text -Key 'Impact.BrowserApplication') }
        if ($productKey -eq '360InstallDir' -or
            @('360 Program Files', '360 Program Files (x86)', '360 ProgramData') -contains $name) {
            return (Get-W360Text -Key 'Impact.SharedInstallDir')
        }
        if ($name -match '(?i)winToolBox updater') { return (Get-W360Text -Key 'Impact.WinToolBoxUpdater') }
        if ($productKey -eq 'WinToolBox360') { return (Get-W360Text -Key 'Impact.WinToolBoxComponent') }
        if ($productKey -eq '360Temp' -or $name -match '(?i)temporary') { return (Get-W360Text -Key 'Impact.TempFiles') }
        $baseKey = if (Test-W360TargetLooksLikeFile -Target $target) { 'Impact.File' } else { 'Impact.Folder' }
        $base = Get-W360Text -Key $baseKey
        if ($productKey -ne 'Unattributed') {
            return ($base + (Get-W360Text -Key 'Common.SentenceSeparator') + (Get-W360ProductInfo -ProductKey $productKey).Impact)
        }
        return $base
    }
    if ($removalType -eq 'RegistryValue') { return (Get-W360Text -Key 'Impact.RegistryValue') }
    if ($removalType -eq 'RegistryKey') { return (Get-W360Text -Key 'Impact.RegistryResidue') }
    if ($removalType -eq 'Service') { return (Get-W360Text -Key 'Impact.Service') }
    if ($removalType -eq 'Task') { return (Get-W360Text -Key 'Impact.Task') }
    if ($removalType -eq 'Process') { return (Get-W360Text -Key 'Impact.Process') }
    return (Get-W360Text -Key 'Impact.Generic')
}

function Get-W360FindingTechnicalText {
    param([AllowNull()][object]$Finding)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($field in @(
        @('Tech.Confidence', 'Confidence'), @('Tech.Kind', 'Kind'), @('Tech.Name', 'Name'),
        @('Tech.Target', 'Target'), @('Tech.ValueName', 'ValueName'), @('Tech.RemovalType', 'RemovalType'),
        @('Tech.ProductKey', 'ProductKey'), @('Tech.SelectionId', 'SelectionId'),
        @('Tech.IdentityFingerprint', 'IdentityFingerprint'), @('Tech.Offline', 'Offline'), @('Tech.Reason', 'Reason')
    )) {
        $label = Get-W360Text -Key $field[0]
        if (Test-W360HasProperty -Object $Finding -Name $field[1]) {
            $lines.Add($label + (Get-W360StringProperty -Object $Finding -Name $field[1]))
        }
        else {
            $lines.Add($label + (Get-W360Text -Key 'Common.NotRecorded'))
        }
    }
    return ($lines.ToArray() -join "`r`n")
}

# Groups the findings by product for the window and the agent. SelectableIds, SelectableCount, ReviewCount,
# KeepReasonText and DecisionText follow the effectively deletable set: a deletable item that can never pass the
# selection check in this check result counts as kept, with its reason.
function Get-W360FindingGroups {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Findings,
        # Get-W360EffectiveDeletableIds of the whole check result. Pass it when the caller already has it (it is worked
        # out from Findings otherwise); it never makes an item deletable that Test-W360FindingSelectable refuses.
        [AllowNull()][object]$Effective
    )

    $allFindings = @(Get-W360Items -Value $Findings)
    if ($null -eq $Effective) { $Effective = Get-W360EffectiveDeletableIds -Findings $allFindings }
    $entriesByKey = @{}
    $index = 0
    foreach ($finding in $allFindings) {
        $key = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $finding -Name 'ProductKey')
        if (-not $entriesByKey.ContainsKey($key)) {
            $entriesByKey[$key] = New-Object System.Collections.ArrayList
        }
        [void]$entriesByKey[$key].Add([pscustomobject]@{
            Finding    = $finding
            Index      = $index
            Deletable  = [bool](Test-W360FindingDeletable -Finding $finding -Effective $Effective)
            Kind       = Get-W360StringProperty -Object $finding -Name 'Kind'
            Target     = Get-W360StringProperty -Object $finding -Name 'Target'
        })
        $index++
    }

    $groups = New-Object System.Collections.ArrayList
    foreach ($key in @($entriesByKey.Keys)) {
        $entries = @($entriesByKey[$key] | Sort-Object -Property @(
            @{ Expression = { if ($_.Deletable) { 0 } else { 1 } } },
            @{ Expression = { $_.Kind } },
            @{ Expression = { $_.Target } },
            @{ Expression = { $_.Index } }
        ))
        $selectableCount = @($entries | Where-Object { $_.Deletable }).Count
        $reviewCount = $entries.Count - $selectableCount
        $selectableIds = New-Object System.Collections.Generic.List[string]
        $keepCodes = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $entries) {
            if ($entry.Deletable) {
                $id = Get-W360FindingSelectionId -Finding $entry.Finding
                if (-not $selectableIds.Contains($id)) { $selectableIds.Add($id) }
            }
            else {
                $code = (Get-W360FindingStatus -Finding $entry.Finding -Effective $Effective).Code
                if (-not $keepCodes.Contains($code)) { $keepCodes.Add($code) }
            }
        }
        # One shared reason names it; mixed reasons fall back to the plain "keep" text.
        $keepReasonText = ''
        if ($reviewCount -gt 0) {
            $keepCode = if ($keepCodes.Count -eq 1) { $keepCodes[0] } else { 'NotRemovable' }
            $keepReasonText = Get-W360Text -Key ('Status.' + $keepCode + '.Text')
        }
        $decisionText = if ($selectableCount -gt 0 -and $reviewCount -gt 0) {
            Get-W360Text -Key 'Ui.Group.CanDeleteSomeKept' -Arguments @($selectableCount, $reviewCount)
        }
        elseif ($selectableCount -gt 0) { Get-W360Text -Key 'Ui.Group.CanDelete' -Arguments @($selectableCount) }
        else { $keepReasonText }
        $info = Get-W360ProductInfo -ProductKey $key
        $tier = if ($key -eq 'Unattributed') { 2 } elseif ($key -eq 'OfflineWindows') { 3 } elseif ($selectableCount -gt 0) { 0 } else { 1 }
        [void]$groups.Add([pscustomobject]@{
            Key             = $key
            DisplayName     = $info.DisplayName
            Description     = $info.Description
            Findings        = @($entries | ForEach-Object { $_.Finding })
            SelectableCount = $selectableCount
            ReviewCount     = $reviewCount
            SelectableIds   = [string[]]$selectableIds.ToArray()
            KeepReasonText  = [string]$keepReasonText
            DecisionText    = [string]$decisionText
            SortTier        = $tier
            SortOrder       = [Array]::IndexOf($script:W360ProductOrder, $key)
        })
    }
    foreach ($group in @($groups | Sort-Object -Property SortTier, SortOrder)) {
        [pscustomobject]@{
            Key             = $group.Key
            DisplayName     = $group.DisplayName
            Description     = $group.Description
            Findings        = $group.Findings
            SelectableCount = $group.SelectableCount
            ReviewCount     = $group.ReviewCount
            SelectableIds   = [string[]]@($group.SelectableIds)
            KeepReasonText  = $group.KeepReasonText
            DecisionText    = $group.DecisionText
        }
    }
}

function ConvertTo-W360NormalPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $text = $Path.Trim()
    if ($text.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { return $null }
    if (-not ($text -match '^[A-Za-z]:[\\/]' -or $text -match '^[\\/]{2}[^\\/]')) { return $null }
    try { $full = [IO.Path]::GetFullPath($text) }
    catch { return $null }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-W360IsUnderPath {
    param(
        [AllowNull()][string]$Candidate,
        [AllowNull()][string]$Root
    )

    $candidatePath = ConvertTo-W360NormalPath -Path $Candidate
    $rootPath = ConvertTo-W360NormalPath -Path $Root
    if (-not $candidatePath -or -not $rootPath) { return $false }
    if ($candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = if ($rootPath.EndsWith('\')) { $rootPath } else { $rootPath + '\' }
    return $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-W360ContainedTarget {
    param([AllowNull()][object]$Finding)

    switch (Get-W360StringProperty -Object $Finding -Name 'Kind') {
        'Path' { return (Get-W360StringProperty -Object $Finding -Name 'Target') }
        'OfflinePath' { return (Get-W360StringProperty -Object $Finding -Name 'Target') }
        'VendorUninstaller' { return (Get-W360StringProperty -Object $Finding -Name 'Target') }
        'Process' { return (Get-W360StringProperty -Object $Finding -Name 'ValueName') }
    }
    return ''
}

function New-W360PlanProblem {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Resolution,
        [string]$ParentSelectionId = '',
        [AllowEmptyCollection()][string[]]$AddSelectionIds = @(),
        [AllowEmptyCollection()][object[]]$BlockingFindings = @()
    )

    return [pscustomobject]@{
        Code              = $Code
        Message           = $Message
        Resolution        = $Resolution
        ParentSelectionId = $ParentSelectionId
        AddSelectionIds   = [string[]]@($AddSelectionIds)
        BlockingFindings  = @($BlockingFindings)
    }
}

function Get-W360SelectionPlan {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Findings,
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds
    )

    $allFindings = @(Get-W360Items -Value $Findings)
    $selectableById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $selectableOrder = New-Object System.Collections.ArrayList
    foreach ($finding in $allFindings) {
        if (-not (Test-W360FindingSelectable -Finding $finding)) { continue }
        $id = Get-W360FindingSelectionId -Finding $finding
        if ($selectableById.ContainsKey($id)) { continue }
        $selectableById[$id] = $finding
        [void]$selectableOrder.Add($id)
    }

    $normalizedIds = New-Object System.Collections.Generic.List[string]
    $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $SelectedIds)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($selectedSet.Add($id)) { $normalizedIds.Add($id) }
    }

    $problems = New-Object System.Collections.ArrayList
    if ($normalizedIds.Count -eq 0) {
        [void]$problems.Add((New-W360PlanProblem -Code 'NothingSelected' `
            -Message (Get-W360Text -Key 'Plan.NothingSelected.Message') `
            -Resolution (Get-W360Text -Key 'Plan.NothingSelected.Resolution')))
    }
    if ($normalizedIds.Count -gt $script:W360MaxSelectedIds) {
        [void]$problems.Add((New-W360PlanProblem -Code 'TooMany' `
            -Message (Get-W360Text -Key 'Plan.TooMany.Message' -Arguments @($normalizedIds.Count, $script:W360MaxSelectedIds)) `
            -Resolution (Get-W360Text -Key 'Plan.TooMany.Resolution')))
    }
    foreach ($id in $normalizedIds) {
        if (-not $selectableById.ContainsKey($id)) {
            [void]$problems.Add((New-W360PlanProblem -Code 'UnknownId' `
                -Message (Get-W360Text -Key 'Plan.UnknownId.Message') `
                -Resolution (Get-W360Text -Key 'Plan.UnknownId.Resolution') -ParentSelectionId $id))
        }
    }

    $selectedFindings = New-Object System.Collections.ArrayList
    $preservedFindings = New-Object System.Collections.ArrayList
    foreach ($id in $selectableOrder) {
        if ($selectedSet.Contains($id)) { [void]$selectedFindings.Add($selectableById[$id]) }
        else { [void]$preservedFindings.Add($selectableById[$id]) }
    }

    # Contained targets, selectable flags and IDs are worked out once per plan: the loop below compares every
    # selected folder with every finding, and the window runs plans on every product-row click.
    $containedPaths = New-Object System.Collections.Generic.List[string]
    $selectableFlags = New-Object System.Collections.Generic.List[bool]
    $candidateIds = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $allFindings) {
        $containedPaths.Add([string](ConvertTo-W360NormalPath -Path (Get-W360ContainedTarget -Finding $candidate)))
        $candidateSelectable = [bool](Test-W360FindingSelectable -Finding $candidate)
        $selectableFlags.Add($candidateSelectable)
        $candidateIds.Add($(if ($candidateSelectable) { Get-W360FindingSelectionId -Finding $candidate } else { '' }))
    }

    foreach ($parent in @($selectedFindings)) {
        if ((Get-W360StringProperty -Object $parent -Name 'RemovalType') -ne 'Path') { continue }
        $parentId = Get-W360FindingSelectionId -Finding $parent
        $parentRoot = ConvertTo-W360NormalPath -Path (Get-W360StringProperty -Object $parent -Name 'Target')
        if (-not $parentRoot) { continue }
        $parentPrefix = if ($parentRoot.EndsWith('\')) { $parentRoot } else { $parentRoot + '\' }
        $selectableChildren = New-Object System.Collections.ArrayList
        $selectableChildIds = New-Object System.Collections.Generic.List[string]
        $protectedChildren = New-Object System.Collections.ArrayList
        for ($candidateIndex = 0; $candidateIndex -lt $allFindings.Count; $candidateIndex++) {
            $candidate = $allFindings[$candidateIndex]
            if ([object]::ReferenceEquals($candidate, $parent)) { continue }
            $containedPath = $containedPaths[$candidateIndex]
            if ([string]::IsNullOrEmpty($containedPath)) { continue }
            if (-not ($containedPath.Equals($parentRoot, [StringComparison]::OrdinalIgnoreCase) -or
                    $containedPath.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase))) { continue }
            if ($selectableFlags[$candidateIndex]) {
                $candidateId = $candidateIds[$candidateIndex]
                if ($selectedSet.Contains($candidateId) -or $selectableChildIds.Contains($candidateId)) { continue }
                $selectableChildIds.Add($candidateId)
                [void]$selectableChildren.Add($candidate)
            }
            else {
                [void]$protectedChildren.Add($candidate)
            }
        }
        if ($selectableChildren.Count -eq 0 -and $protectedChildren.Count -eq 0) { continue }
        $parentName = Get-W360FindingDisplayName -Finding $parent
        if ($selectableChildren.Count -gt 0) {
            [void]$problems.Add((New-W360PlanProblem -Code 'ParentContainsSelectableChild' `
                -Message (Get-W360Text -Key 'Plan.ParentContainsSelectableChild.Message' -Arguments @(
                    $parentName, $selectableChildren.Count, (Get-W360FindingDisplayName -Finding $selectableChildren[0]))) `
                -Resolution (Get-W360Text -Key 'Plan.ParentContainsSelectableChild.Resolution' -Arguments @($parentName)) `
                -ParentSelectionId $parentId -AddSelectionIds $selectableChildIds.ToArray() `
                -BlockingFindings @($selectableChildren)))
        }
        if ($protectedChildren.Count -gt 0) {
            [void]$problems.Add((New-W360PlanProblem -Code 'ParentContainsProtectedChild' `
                -Message (Get-W360Text -Key 'Plan.ParentContainsProtectedChild.Message' -Arguments @(
                    $parentName, $protectedChildren.Count, (Get-W360FindingDisplayName -Finding $protectedChildren[0]))) `
                -Resolution (Get-W360Text -Key 'Plan.ParentContainsProtectedChild.Resolution' -Arguments @($parentName)) `
                -ParentSelectionId $parentId -BlockingFindings @($protectedChildren)))
        }
    }

    $vendorSelected = $false
    foreach ($vendor in @($selectedFindings)) {
        if ((Get-W360StringProperty -Object $vendor -Name 'Kind') -ne 'VendorUninstaller' -and
            (Get-W360StringProperty -Object $vendor -Name 'RemovalType') -ne 'VendorUninstaller') { continue }
        $vendorSelected = $true
        $vendorPath = ConvertTo-W360NormalPath -Path (Get-W360StringProperty -Object $vendor -Name 'Target')
        $installRoot = $null
        if ($vendorPath) {
            try { $installRoot = ConvertTo-W360NormalPath -Path ([IO.Path]::GetDirectoryName($vendorPath)) }
            catch { $installRoot = $null }
        }
        $rootSelected = $false
        $rootCandidate = $null
        if ($installRoot) {
            foreach ($finding in $allFindings) {
                if ((Get-W360StringProperty -Object $finding -Name 'Kind') -ne 'Path' -or
                    (Get-W360StringProperty -Object $finding -Name 'RemovalType') -ne 'Path') { continue }
                $findingPath = ConvertTo-W360NormalPath -Path (Get-W360StringProperty -Object $finding -Name 'Target')
                if (-not $findingPath -or -not $findingPath.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not (Test-W360FindingSelectable -Finding $finding)) { continue }
                if ($selectedSet.Contains((Get-W360FindingSelectionId -Finding $finding))) { $rootSelected = $true; break }
                if ($null -eq $rootCandidate) { $rootCandidate = $finding }
            }
        }
        if ($rootSelected) { continue }
        $vendorName = Get-W360FindingDisplayName -Finding $vendor
        $rootName = if ($null -ne $rootCandidate) { Get-W360FindingDisplayName -Finding $rootCandidate } elseif ($installRoot) { $installRoot } else { Get-W360Text -Key 'Common.Unknown' }
        $addIds = @()
        $resolution = Get-W360Text -Key 'Plan.VendorUninstallerNeedsInstallRoot.ResolutionUnavailable'
        if ($null -ne $rootCandidate) {
            $addIds = @(Get-W360FindingSelectionId -Finding $rootCandidate)
            $resolution = Get-W360Text -Key 'Plan.VendorUninstallerNeedsInstallRoot.Resolution' -Arguments @($rootName)
        }
        [void]$problems.Add((New-W360PlanProblem -Code 'VendorUninstallerNeedsInstallRoot' `
            -Message (Get-W360Text -Key 'Plan.VendorUninstallerNeedsInstallRoot.Message' -Arguments @($vendorName, $rootName)) `
            -Resolution $resolution -ParentSelectionId (Get-W360FindingSelectionId -Finding $vendor) `
            -AddSelectionIds $addIds -BlockingFindings @($vendor)))
    }

    $affectedKeys = New-Object System.Collections.Generic.List[string]
    foreach ($finding in @($selectedFindings)) {
        $key = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $finding -Name 'ProductKey')
        if (-not $affectedKeys.Contains($key)) { $affectedKeys.Add($key) }
    }

    return [pscustomobject]@{
        CanSubmit                 = ($problems.Count -eq 0)
        Problems                  = @($problems)
        SelectedFindings          = @($selectedFindings)
        PreservedFindings         = @($preservedFindings)
        VendorUninstallerSelected = [bool]$vendorSelected
        AffectedProductKeys       = [string[]]$affectedKeys.ToArray()
        SelectedIds               = [string[]]$normalizedIds.ToArray()
    }
}

function Add-W360PlanSelections {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds,
        [Parameter(Mandatory = $true)][object]$Problem
    )

    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $SelectedIds)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($seen.Add($id)) { $result.Add($id) }
    }
    foreach ($rawId in @(Get-W360ArrayProperty -Object $Problem -Name 'AddSelectionIds')) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ($id -notmatch '^[0-9A-F]{64}$') { continue }
        if ($seen.Add($id)) { $result.Add($id) }
    }
    return [string[]]$result.ToArray()
}

# Adds the selectable CandidateIds (for example every deletable item of one product row) to the SelectedIds and
# shrinks the result to the largest safe set: every added parent folder or uninstaller that Get-W360SelectionPlan
# objects to is removed again, round by round, until no added ID causes a problem. Removing an ID can only create
# problems, never solve one for another ID, so the fixed point is the unique largest safe set.
# - Only selectable findings are ever returned; nothing outside SelectedIds and CandidateIds is ever added.
# - Already selected IDs (the user clicked them) are never removed, even when they have a problem of their own.
# - NothingSelected and TooMany are ignored here; the counter and the plan dialog report them.
# Returns Ids and AddedIds (findings order) and Removed (round order, then findings order) with a plain reason and the
# RelatedIds of the plan problem that removed the ID.
function Get-W360DeletableSelection {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Findings,
        [AllowNull()][AllowEmptyCollection()][string[]]$CandidateIds,
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds
    )

    $allFindings = @(Get-W360Items -Value $Findings)
    $order = New-Object System.Collections.Generic.List[string]
    $findingById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $allFindings) {
        if (-not (Test-W360FindingSelectable -Finding $finding)) { continue }
        $id = Get-W360FindingSelectionId -Finding $finding
        if ($findingById.ContainsKey($id)) { continue }
        $findingById[$id] = $finding
        $order.Add($id)
    }

    $baseSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $SelectedIds)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ($findingById.ContainsKey($id)) { [void]$baseSet.Add($id) }
    }
    $addedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $CandidateIds)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ($findingById.ContainsKey($id) -and -not $baseSet.Contains($id)) { [void]$addedSet.Add($id) }
    }

    # Earlier codes win when one ID has several problems: the protected-content reason is the most important one.
    $offendingCodes = @('ParentContainsProtectedChild', 'VendorUninstallerNeedsInstallRoot', 'ParentContainsSelectableChild')
    $removed = New-Object System.Collections.ArrayList
    while ($addedSet.Count -gt 0) {
        $current = New-Object System.Collections.Generic.List[string]
        foreach ($id in $order) { if ($baseSet.Contains($id) -or $addedSet.Contains($id)) { $current.Add($id) } }
        $plan = Get-W360SelectionPlan -Findings $allFindings -SelectedIds $current.ToArray()
        $codeById = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        $relatedById = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($problem in @(Get-W360ArrayProperty -Object $plan -Name 'Problems')) {
            $code = Get-W360StringProperty -Object $problem -Name 'Code'
            $rank = [Array]::IndexOf($offendingCodes, $code)
            if ($rank -lt 0) { continue }
            $parentId = (Get-W360StringProperty -Object $problem -Name 'ParentSelectionId').Trim().ToUpperInvariant()
            if (-not $addedSet.Contains($parentId)) { continue }
            if (-not $codeById.ContainsKey($parentId) -or $rank -lt [Array]::IndexOf($offendingCodes, $codeById[$parentId])) {
                $codeById[$parentId] = $code
                $relatedById[$parentId] = [string[]]@(@(Get-W360ArrayProperty -Object $problem -Name 'AddSelectionIds') | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
            }
        }
        if ($codeById.Count -eq 0) { break }
        foreach ($id in $order) {
            if (-not $codeById.ContainsKey($id)) { continue }
            [void]$addedSet.Remove($id)
            $code = $codeById[$id]
            # The IDs the problem named as the way out (the folder an uninstaller needs, the items a folder holds).
            $relatedIds = [string[]]@()
            if ($relatedById.ContainsKey($id)) { $relatedIds = $relatedById[$id] }
            [void]$removed.Add([pscustomobject]@{
                SelectionId = $id
                DisplayName = Get-W360FindingDisplayName -Finding $findingById[$id]
                Code        = $code
                ReasonText  = Get-W360Text -Key ('Ui.Select.SkipReason.' + $code)
                Finding     = $findingById[$id]
                RelatedIds  = $relatedIds
            })
        }
    }

    $ids = New-Object System.Collections.Generic.List[string]
    $addedIds = New-Object System.Collections.Generic.List[string]
    foreach ($id in $order) {
        if ($addedSet.Contains($id)) { $addedIds.Add($id) }
        if ($baseSet.Contains($id) -or $addedSet.Contains($id)) { $ids.Add($id) }
    }
    return [pscustomobject]@{
        Ids      = [string[]]$ids.ToArray()
        AddedIds = [string[]]$addedIds.ToArray()
        Removed  = @($removed)
    }
}

# The effectively deletable items of one check result: a display and choice layer, worked out once per findings list.
# Get-W360DeletableSelection only ever shrinks, and removing an item can only create problems for other items, never
# solve one. So asking it for every deletable item at once gives the largest set of items that pass the selection check
# together, and every selection that passes the check lies inside that set. A deletable item outside it can never be
# deleted in this check result (for example a folder that holds something that is kept, or an uninstaller whose folder
# cannot be deleted), so the window and the agent show it as "won't delete" with the reason and never offer it.
# It only narrows: Ids is always a subset of the deletable items (Test-W360FindingSelectable), and the selection plan,
# the confirmation and the core approval checks are unchanged.
# Returns Ids (findings order), IdSet (case-insensitive), Removed (removal order: SelectionId, DisplayName, Code of the
# plan problem, StatusCode, ReasonText, Finding), RemovedById and SelectableCount (deletable IDs before narrowing).
function Get-W360EffectiveDeletableIds {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Findings)

    $allFindings = @(Get-W360Items -Value $Findings)
    $candidateIds = New-Object System.Collections.Generic.List[string]
    $candidateSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $allFindings) {
        if (-not (Test-W360FindingSelectable -Finding $finding)) { continue }
        $id = Get-W360FindingSelectionId -Finding $finding
        if ($candidateSet.Add($id)) { $candidateIds.Add($id) }
    }

    $ids = New-Object System.Collections.Generic.List[string]
    $idSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $removed = New-Object System.Collections.ArrayList
    $removedById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    if ($candidateIds.Count -gt 0) {
        $shrunk = Get-W360DeletableSelection -Findings $allFindings -CandidateIds $candidateIds.ToArray() -SelectedIds @()
        foreach ($rawId in @($shrunk.Ids)) {
            # Checked again against the deletable items of this list, so the set can never grow beyond them.
            $id = [string]$rawId
            if ($candidateSet.Contains($id) -and $idSet.Add($id)) { $ids.Add($id) }
        }
        foreach ($item in @($shrunk.Removed)) {
            $id = [string]$item.SelectionId
            if ($idSet.Contains($id) -or $removedById.ContainsKey($id)) { continue }
            $code = [string]$item.Code
            $statusCode = if ($code -eq 'VendorUninstallerNeedsInstallRoot') { 'NeedsItsFolder' } else { 'KeptContentInside' }
            $entry = [pscustomobject]@{
                SelectionId = $id
                DisplayName = [string]$item.DisplayName
                Code        = $code
                StatusCode  = $statusCode
                ReasonText  = Get-W360KeepReason -StatusText (Get-W360Text -Key ('Status.' + $statusCode + '.Text'))
                Finding     = $item.Finding
            }
            [void]$removed.Add($entry)
            $removedById[$id] = $entry
        }
    }
    return [pscustomobject]@{
        Ids             = [string[]]$ids.ToArray()
        IdSet           = $idSet
        Removed         = @($removed)
        RemovedById     = $removedById
        SelectableCount = $candidateIds.Count
    }
}

# True only for an item that is deletable (Test-W360FindingSelectable) and inside the effectively deletable set of its
# check result (Get-W360EffectiveDeletableIds). A missing or malformed set counts as empty, so it can never widen.
function Test-W360FindingDeletable {
    param(
        [AllowNull()][object]$Finding,
        [AllowNull()][object]$Effective
    )

    if (-not (Test-W360FindingSelectable -Finding $Finding)) { return $false }
    if ($null -eq $Effective -or $null -eq $Effective.PSObject.Properties['IdSet']) { return $false }
    # Read into a variable: returning the set from a helper would unroll it into its items.
    $idSet = $Effective.PSObject.Properties['IdSet'].Value
    if ($idSet -isnot [System.Collections.Generic.HashSet[string]]) { return $false }
    return $idSet.Contains((Get-W360FindingSelectionId -Finding $Finding))
}

# The status code of a deletable item outside the effectively deletable set: the plain reason it was left out, or the
# plain "won't delete" when the set does not know the item.
function Get-W360EffectiveKeepCode {
    param(
        [AllowNull()][object]$Effective,
        [AllowNull()][AllowEmptyString()][string]$SelectionId
    )

    if ($null -eq $Effective -or [string]::IsNullOrWhiteSpace($SelectionId) -or $null -eq $Effective.PSObject.Properties['RemovedById']) { return 'NotRemovable' }
    $removedById = $Effective.PSObject.Properties['RemovedById'].Value
    if ($removedById -isnot [System.Collections.Generic.Dictionary[string,object]] -or -not $removedById.ContainsKey($SelectionId.Trim())) { return 'NotRemovable' }
    $statusCode = [string]$removedById[$SelectionId.Trim()].StatusCode
    if (@('KeptContentInside', 'NeedsItsFolder') -ccontains $statusCode) { return $statusCode }
    return 'NotRemovable'
}

# The effectively deletable set a scan outcome carries (Get-W360ScanOutcome works it out once), or a new one worked out
# from the outcome's findings when the outcome has none.
function Get-W360OutcomeEffectiveDeletable {
    param([AllowNull()][object]$Outcome)

    if ($null -ne $Outcome -and $null -ne $Outcome.PSObject.Properties['EffectiveDeletable']) {
        $effective = $Outcome.PSObject.Properties['EffectiveDeletable'].Value
        if ($null -ne $effective -and $null -ne $effective.PSObject.Properties['IdSet'] -and
            $effective.PSObject.Properties['IdSet'].Value -is [System.Collections.Generic.HashSet[string]]) {
            return $effective
        }
    }
    return (Get-W360EffectiveDeletableIds -Findings @(Get-W360ArrayProperty -Object $Outcome -Name 'Findings'))
}

# True for an uninstaller that came with 360: it is run, not deleted like a file.
function Test-W360FindingIsUninstaller {
    param([AllowNull()][object]$Finding)

    return ((Get-W360StringProperty -Object $Finding -Name 'Kind') -eq 'VendorUninstaller' -or
        (Get-W360StringProperty -Object $Finding -Name 'RemovalType') -eq 'VendorUninstaller')
}

# The reason part of a "do not delete: reason" status ("书签和历史记录"); the plain status when it has no reason.
function Get-W360KeepReason {
    param([AllowNull()][AllowEmptyString()][string]$StatusText)

    $text = [string]$StatusText
    $prefix = Get-W360Text -Key 'Status.KeepPrefix'
    if ($text.StartsWith($prefix, [StringComparison]::Ordinal)) {
        $rest = $text.Substring($prefix.Length).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rest)) { return $rest }
    }
    return $text
}

# The "kept" part of a confirmation: every product or item that is not deleted, in plain words, with the product
# it belongs to ({ProductKey; Text}). SelectedIdSet holds the selected SelectionIds (OrdinalIgnoreCase).
function Get-W360ConfirmKeptLines {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$AllFindings,
        [Parameter(Mandatory = $true)][object]$SelectedIdSet,
        # Get-W360EffectiveDeletableIds of AllFindings; worked out here when omitted.
        [AllowNull()][object]$Effective,
        # SelectionIds that were chosen but left out by Get-W360DeletableSelection (for example a product the user named
        # in the agent route): they are told as "cannot be deleted on its own this time", never as "not selected".
        [AllowNull()][AllowEmptyCollection()][string[]]$SkippedIds
    )

    $all = @(Get-W360Items -Value $AllFindings)
    if ($null -eq $Effective) { $Effective = Get-W360EffectiveDeletableIds -Findings $all }
    $skippedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $SkippedIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$rawId)) { [void]$skippedSet.Add(([string]$rawId).Trim()) }
    }
    $lines = New-Object System.Collections.ArrayList
    foreach ($group in @(Get-W360FindingGroups -Findings $all -Effective $Effective)) {
        $groupFindings = @($group.Findings)
        $selectedInGroup = @($groupFindings | Where-Object {
                (Test-W360FindingSelectable -Finding $_) -and $SelectedIdSet.Contains((Get-W360FindingSelectionId -Finding $_))
            }).Count
        $skippedInGroup = 0
        if ($skippedSet.Count -gt 0) {
            $skippedInGroup = @($groupFindings | Where-Object {
                    (Test-W360FindingDeletable -Finding $_ -Effective $Effective) -and $skippedSet.Contains((Get-W360FindingSelectionId -Finding $_))
                }).Count
        }
        if ($selectedInGroup -eq 0 -and $skippedInGroup -eq 0) {
            $text = if ([int]$group.SelectableCount -gt 0) {
                Get-W360Text -Key 'Ui.Confirm.NotSelected' -Arguments @([string]$group.DisplayName)
            }
            else {
                Get-W360Text -Key 'Ui.Confirm.KeptReason' -Arguments @([string]$group.DisplayName, (Get-W360KeepReason -StatusText ([string]$group.KeepReasonText)))
            }
            [void]$lines.Add([pscustomobject]@{ ProductKey = [string]$group.Key; Text = $text })
            continue
        }
        foreach ($finding in $groupFindings) {
            if ((Test-W360FindingSelectable -Finding $finding) -and $SelectedIdSet.Contains((Get-W360FindingSelectionId -Finding $finding))) { continue }
            if (Test-W360FindingDeletable -Finding $finding -Effective $Effective) {
                $notSelectedKey = if ($skippedSet.Contains((Get-W360FindingSelectionId -Finding $finding))) { 'Ui.Confirm.SkippedThisTime' } else { 'Ui.Confirm.NotSelected' }
                $text = Get-W360Text -Key $notSelectedKey -Arguments @((Get-W360FindingDisplayName -Finding $finding))
            }
            else {
                $keptStatus = Get-W360FindingStatus -Finding $finding -Effective $Effective
                $keptName = Get-W360FindingDisplayName -Finding $finding
                $rawName = (Get-W360StringProperty -Object $finding -Name 'Name').Trim()
                # A known browser profile name already says "personal data (bookmarks, history, ...)"; repeating the
                # reason in a second pair of brackets only adds noise.
                $text = if ($keptStatus.Code -eq 'PersonalDataKept' -and $script:W360FindingNameKeys.ContainsKey($rawName)) { $keptName }
                else { Get-W360Text -Key 'Ui.Confirm.KeptReason' -Arguments @($keptName, (Get-W360KeepReason -StatusText $keptStatus.Text)) }
            }
            [void]$lines.Add([pscustomobject]@{ ProductKey = [string]$group.Key; Text = $text })
        }
    }
    return @($lines)
}

# The item list of a deletion confirmation, shared by the guided window's confirmation dialog and by
# scripts/Show-360Summary.ps1 so both say the same words: what is deleted (by product), what deleting does (once per
# different effect) and what is kept. With an uninstaller that came with 360 selected, unselected parts of its own
# product are never promised to be kept; other products are only promised not to be deleted by this tool.
# The permanence line, the uninstaller warning and the "close 360 programs" note are separate texts
# (Ui.Confirm.PermanentDelete, Ui.Confirm.VendorWarning, Ui.Confirm.CloseApps) that each front end places itself.
function Get-W360ConfirmText {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        # Every finding of the check (selected, not selected and kept); used for the "kept" list.
        [AllowNull()][AllowEmptyCollection()][object[]]$AllFindings,
        [ValidateRange(1, 1000)][int]$KeptLineLimit = 10,
        # 'zh' or 'en' for this call only; empty keeps the current language.
        [AllowEmptyString()][string]$Language = '',
        # Get-W360EffectiveDeletableIds of AllFindings when the caller already has it; worked out here otherwise.
        [AllowNull()][object]$Effective,
        # Chosen SelectionIds that Get-W360DeletableSelection left out (Get-W360ConfirmKeptLines).
        [AllowNull()][AllowEmptyCollection()][string[]]$SkippedIds
    )

    if (-not [string]::IsNullOrEmpty($Language) -and @('zh', 'en') -notcontains $Language) {
        throw "Unsupported confirmation language: $Language"
    }
    $previousLanguage = $script:W360UiLanguage
    if (-not [string]::IsNullOrEmpty($Language)) { Set-W360UiLanguage -Language $Language }
    try {
        $selected = @(Get-W360ArrayProperty -Object $Plan -Name 'SelectedFindings')
        $all = @(Get-W360Items -Value $AllFindings)
        if ($all.Count -eq 0) { $all = @($selected) + @(Get-W360ArrayProperty -Object $Plan -Name 'PreservedFindings') }
        if ($null -eq $Effective) { $Effective = Get-W360EffectiveDeletableIds -Findings $all }
        $selectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($finding in $selected) { [void]$selectedIds.Add((Get-W360FindingSelectionId -Finding $finding)) }
        $bullet = [string][char]0x25CF
        $dot = [string][char]0x00B7
        $separator = Get-W360Text -Key 'Common.ListSeparator'

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((Get-W360Text -Key 'Ui.Confirm.DeleteTitle' -Arguments @($selected.Count)))
        # Every item of a plan that passed its checks is effectively deletable, so the check result's set groups them.
        foreach ($group in @(Get-W360FindingGroups -Findings $selected -Effective $Effective)) {
            $lines.Add(($bullet + ' ' + (Get-W360Text -Key 'Ui.Confirm.GroupLine' -Arguments @([string]$group.DisplayName, @($group.Findings).Count))))
            foreach ($finding in @($group.Findings)) {
                $name = Get-W360FindingDisplayName -Finding $finding
                # An uninstaller that came with 360 is run, not deleted like a file; the list says so.
                if (Test-W360FindingIsUninstaller -Finding $finding) { $name = Get-W360Text -Key 'Ui.Confirm.RunUninstaller' -Arguments @($name) }
                $lines.Add(('      ' + $name))
            }
        }

        # What deleting does, once per different effect, with the names of the items it applies to.
        $lines.Add('')
        $lines.Add((Get-W360Text -Key 'Ui.Confirm.AfterTitle'))
        $impactOrder = New-Object System.Collections.Generic.List[string]
        $namesByImpact = @{}
        $uninstallerImpact = Get-W360Text -Key 'Impact.VendorUninstaller.Confirm'
        foreach ($finding in $selected) {
            $impact = if (Test-W360FindingIsUninstaller -Finding $finding) { $uninstallerImpact } else { Get-W360ImpactText -Finding $finding }
            if (-not $namesByImpact.ContainsKey($impact)) {
                $namesByImpact[$impact] = New-Object System.Collections.Generic.List[string]
                $impactOrder.Add($impact)
            }
            $namesByImpact[$impact].Add((Get-W360FindingDisplayName -Finding $finding))
        }
        foreach ($impact in $impactOrder) {
            # The uninstaller sentence already names the uninstaller.
            if ($impact -ceq $uninstallerImpact) {
                $lines.Add(($dot + ' ' + $impact))
                continue
            }
            $names = @($namesByImpact[$impact])
            $namesText = if ($names.Count -le 2) { $names -join $separator }
            else { Get-W360Text -Key 'Ui.Confirm.NameMore' -Arguments @((@($names[0], $names[1]) -join $separator), $names.Count) }
            $lines.Add(($dot + ' ' + (Get-W360Text -Key 'Ui.Confirm.ImpactLine' -Arguments @($namesText, $impact))))
        }

        $addKeptSection = {
            param([string]$TitleKey, [object[]]$Kept)
            $items = @(Get-W360Items -Value $Kept)
            if ($items.Count -eq 0) { return }
            $lines.Add('')
            $lines.Add((Get-W360Text -Key $TitleKey))
            $shown = [Math]::Min($items.Count, $KeptLineLimit)
            for ($index = 0; $index -lt $shown; $index++) { $lines.Add(($dot + ' ' + [string]$items[$index].Text)) }
            if ($items.Count -gt $shown) { $lines.Add((Get-W360Text -Key 'Common.MoreItems' -Arguments @($items.Count - $shown))) }
        }
        $kept = @(Get-W360ConfirmKeptLines -AllFindings $all -SelectedIdSet $selectedIds -Effective $Effective -SkippedIds $SkippedIds)
        if ([bool](Get-W360PropertyValue -Object $Plan -Name 'VendorUninstallerSelected')) {
            $vendorKeys = New-Object System.Collections.Generic.List[string]
            foreach ($finding in $selected) {
                if (-not (Test-W360FindingIsUninstaller -Finding $finding)) { continue }
                $vendorKey = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $finding -Name 'ProductKey')
                if (-not $vendorKeys.Contains($vendorKey)) { $vendorKeys.Add($vendorKey) }
            }
            & $addKeptSection 'Ui.Confirm.KeptSameProduct' @($kept | Where-Object { $vendorKeys.Contains([string]$_.ProductKey) })
            & $addKeptSection 'Ui.Confirm.KeptOther' @($kept | Where-Object { -not $vendorKeys.Contains([string]$_.ProductKey) })
        }
        else {
            & $addKeptSection 'Ui.Confirm.KeptTitle' $kept
        }
        return ($lines.ToArray() -join "`r`n")
    }
    finally { $script:W360UiLanguage = $previousLanguage }
}

function ConvertTo-W360ProcessArgument {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    if ($Value.IndexOfAny([char[]]@([char]'"', [char]13, [char]10)) -ge 0) {
        throw 'A child-process argument contains an unsupported quote or line break.'
    }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '\s') { return $Value }
    # Inside quotes, trailing backslashes must be doubled so the closing quote is not escaped.
    $trailing = [regex]::Match($Value, '\\+$').Length
    return '"' + $Value + ('\' * $trailing) + '"'
}

function Test-W360ArgumentsRequestRemove {
    param([AllowNull()][AllowEmptyCollection()][object[]]$ArgumentList)

    $items = @(Get-W360Items -Value $ArgumentList | ForEach-Object { ([string]$_).Trim() })
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        if ($item -ieq '-ConfirmRemoval' -or $item -imatch '^-Mode:\s*Remove$') { return $true }
        if ($item -ieq '-Mode' -and $index + 1 -lt $items.Count -and $items[$index + 1] -ieq 'Remove') { return $true }
    }
    return $false
}

function Start-W360ChildProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList = @()
    )

    $arguments = @(Get-W360Items -Value $ArgumentList | ForEach-Object { [string]$_ })
    $argumentText = @($arguments | ForEach-Object { ConvertTo-W360ProcessArgument -Value $_ }) -join ' '
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $argumentText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "The child process could not be started: $FilePath" }

    $state = [pscustomobject]@{
        Process                  = $process
        FilePath                 = $FilePath
        ArgumentList             = [string[]]$arguments
        Stopwatch                = [System.Diagnostics.Stopwatch]::StartNew()
        StdoutLines              = New-Object System.Collections.ArrayList
        StderrLines              = New-Object System.Collections.ArrayList
        StdoutLineCount          = [long]0
        StderrLineCount          = [long]0
        Events                   = New-Object System.Collections.ArrayList
        OutTask                  = $null
        ErrTask                  = $null
        OutEof                   = $false
        ErrEof                   = $false
        ExitCode                 = $null
        Completed                = $false
        Cancelled                = $false
        ProgressFileOffset       = [long]0
        ExitObservedMilliseconds = $null
        StreamsAbandoned         = $false
    }
    # Start reading both pipes immediately so a chatty child can never block on a full pipe.
    $state.OutTask = $process.StandardOutput.ReadLineAsync()
    $state.ErrTask = $process.StandardError.ReadLineAsync()
    return $state
}

function Read-W360ProgressFileUpdate {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Final
    )

    $added = 0
    try {
        $leaf = [IO.Path]::GetFileName($Path)
        if ($leaf -cnotmatch $script:W360ProgressLeafPattern) { return 0 }
        if (-not [IO.File]::Exists($Path)) { return 0 }
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            for ($round = 0; $round -lt 16; $round++) {
                $offset = [long]$State.ProgressFileOffset
                $length = $stream.Length
                if ($length -le $offset) { break }
                $toRead = [int][Math]::Min([long]1048576, $length - $offset)
                $buffer = New-Object byte[] $toRead
                $stream.Position = $offset
                $read = 0
                while ($read -lt $toRead) {
                    $count = $stream.Read($buffer, $read, $toRead - $read)
                    if ($count -le 0) { break }
                    $read += $count
                }
                if ($read -le 0) { break }
                $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
                if ($end -lt 0) {
                    if (-not $Final) { break }
                    $end = $read - 1
                }
                $consume = $end + 1
                $text = (New-Object System.Text.UTF8Encoding($false, $false)).GetString($buffer, 0, $consume)
                $State.ProgressFileOffset = $offset + $consume
                foreach ($rawLine in ($text -split "`n")) {
                    $line = $rawLine.TrimEnd("`r")
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $parsed = ConvertFrom-W360ProgressFileLine -Line $line
                    if ($null -eq $parsed) { continue }
                    [void]$State.Events.Add([pscustomobject]@{
                        Phase  = $parsed.Phase
                        Detail = $parsed.Detail
                        Source = 'File'
                        Time   = $parsed.Time
                    })
                    $added++
                }
                if (-not $Final -and $consume -lt $read) { break }
            }
        }
        finally { $stream.Dispose() }
    }
    catch { return $added }
    return $added
}

function Update-W360ChildProcess {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [AllowNull()][AllowEmptyString()][string]$ProgressFilePath,
        [ValidateRange(0, 1000)][int]$TimeBudgetMilliseconds = 50
    )

    if ($State.Completed) { return 0 }
    $added = 0
    $budget = [System.Diagnostics.Stopwatch]::StartNew()
    $maxLines = $script:W360MaxRetainedLines

    while ($true) {
        $progressed = $false

        $burst = 0
        while ($burst -lt 512 -and -not $State.OutEof -and $State.OutTask.IsCompleted) {
            if ([string]$State.OutTask.Status -ne 'RanToCompletion') { $State.OutEof = $true; break }
            $line = $State.OutTask.Result
            if ($null -eq $line) { $State.OutEof = $true; break }
            [void]$State.StdoutLines.Add($line)
            $State.StdoutLineCount++
            $added++
            if ($line.StartsWith('W360-PROGRESS|', [StringComparison]::Ordinal)) {
                $parsed = ConvertFrom-W360ProgressLine -Line $line
                if ($null -ne $parsed) {
                    [void]$State.Events.Add([pscustomobject]@{
                        Phase  = $parsed.Phase
                        Detail = $parsed.Detail
                        Source = 'Stdout'
                        Time   = [DateTime]::Now
                    })
                    $added++
                }
            }
            $State.OutTask = $State.Process.StandardOutput.ReadLineAsync()
            $progressed = $true
            $burst++
        }

        $burst = 0
        while ($burst -lt 512 -and -not $State.ErrEof -and $State.ErrTask.IsCompleted) {
            if ([string]$State.ErrTask.Status -ne 'RanToCompletion') { $State.ErrEof = $true; break }
            $line = $State.ErrTask.Result
            if ($null -eq $line) { $State.ErrEof = $true; break }
            [void]$State.StderrLines.Add($line)
            $State.StderrLineCount++
            $added++
            $State.ErrTask = $State.Process.StandardError.ReadLineAsync()
            $progressed = $true
            $burst++
        }

        if ($State.StdoutLines.Count -gt $maxLines) { $State.StdoutLines.RemoveRange(0, $State.StdoutLines.Count - $maxLines) }
        if ($State.StderrLines.Count -gt $maxLines) { $State.StderrLines.RemoveRange(0, $State.StderrLines.Count - $maxLines) }

        if ($State.OutEof -and $State.ErrEof) { break }
        $remaining = $TimeBudgetMilliseconds - [int]$budget.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        if (-not $progressed) {
            # Give a busy child a brief chance to refill the pipes, bounded by the time budget.
            $pending = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
            if (-not $State.OutEof) { $pending.Add($State.OutTask) }
            if (-not $State.ErrEof) { $pending.Add($State.ErrTask) }
            $waited = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), [Math]::Min($remaining, 15))
            if ($waited -lt 0) { break }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProgressFilePath)) {
        $added += Read-W360ProgressFileUpdate -State $State -Path $ProgressFilePath
    }

    $exited = $false
    try { $exited = $State.Process.HasExited }
    catch { $exited = $true }
    if ($exited) {
        if ($null -eq $State.ExitObservedMilliseconds) {
            $State.ExitObservedMilliseconds = [long]$State.Stopwatch.ElapsedMilliseconds
        }
        if (-not ($State.OutEof -and $State.ErrEof)) {
            # A grandchild that inherited the pipes can keep them open; never wait for it forever.
            $grace = if ($State.Cancelled) { 3000 } else { 10000 }
            if (([long]$State.Stopwatch.ElapsedMilliseconds - [long]$State.ExitObservedMilliseconds) -ge $grace) {
                $State.OutEof = $true
                $State.ErrEof = $true
                $State.StreamsAbandoned = $true
            }
        }
        if ($State.OutEof -and $State.ErrEof) {
            try { [void]$State.Process.WaitForExit(5000) }
            catch {}
            try { $State.ExitCode = [int]$State.Process.ExitCode }
            catch { $State.ExitCode = $null }
            if (-not [string]::IsNullOrWhiteSpace($ProgressFilePath)) {
                $added += Read-W360ProgressFileUpdate -State $State -Path $ProgressFilePath -Final
            }
            $State.Completed = $true
            $State.Stopwatch.Stop()
        }
    }
    return $added
}

function Stop-W360ChildProcess {
    param([Parameter(Mandatory = $true)][object]$State)

    if (Test-W360ArgumentsRequestRemove -ArgumentList @(Get-W360ArrayProperty -Object $State -Name 'ArgumentList')) {
        throw 'Stop-W360ChildProcess is only for Scan or Verify. A running Remove must never be cancelled.'
    }
    if ($State.Completed) { return }
    try {
        if (-not $State.Process.HasExited) { $State.Process.Kill() }
    }
    catch {}
    $State.Cancelled = $true
}

function ConvertFrom-W360ProgressLine {
    param([AllowNull()][string]$Line)

    if ($null -eq $Line) { return $null }
    $match = [regex]::Match($Line.TrimEnd("`r"), '^W360-PROGRESS\|([A-Za-z][A-Za-z0-9]{0,63})\|([^|\r\n]{0,300})$')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Phase  = $match.Groups[1].Value
        Detail = $match.Groups[2].Value
    }
}

function ConvertFrom-W360ProgressFileLine {
    param([AllowNull()][string]$Line)

    if ($null -eq $Line) { return $null }
    $match = [regex]::Match($Line.TrimEnd("`r"),
        '^(\d{4}-\d{2}-\d{2}T[0-9:.]+(?:Z|[+-]\d{2}:\d{2})?)\|([A-Za-z][A-Za-z0-9]{0,63})\|([^|\r\n]{0,300})$')
    if (-not $match.Success) { return $null }
    $time = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$time)) {
        return $null
    }
    return [pscustomobject]@{
        Time   = $time
        Phase  = $match.Groups[2].Value
        Detail = $match.Groups[3].Value
    }
}

function Get-W360PhaseText {
    param([AllowNull()][string]$Phase)

    if (-not [string]::IsNullOrWhiteSpace($Phase) -and $Phase -match '^[A-Za-z][A-Za-z0-9]*$') {
        $key = 'Phase.' + $Phase
        if ($script:W360Strings.ContainsKey($key)) { return (Get-W360Text -Key $key) }
    }
    return (Get-W360Text -Key 'Phase.Unknown')
}

function New-W360ProgressFilePath {
    return [IO.Path]::Combine([IO.Path]::GetTempPath(),
        ('windows-360-cleaner-progress-' + [Guid]::NewGuid().ToString('N').ToLowerInvariant() + '.log'))
}

function Remove-W360ProgressFile {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $full = [IO.Path]::GetFullPath($Path)
        $leaf = [IO.Path]::GetFileName($full)
        if ($leaf -cnotmatch $script:W360ProgressLeafPattern) { return }
        $parent = ([IO.Path]::GetDirectoryName($full)).TrimEnd('\')
        $tempRoot = ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\')
        if (-not $parent.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
        $info = New-Object IO.FileInfo($full)
        if (-not $info.Exists) { return }
        $attributes = $info.Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return }
        $info.Delete()
    }
    catch {}
}

function Get-W360DefaultReportDirectory {
    $desktop = ''
    try { $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop) }
    catch { $desktop = '' }
    if (-not [string]::IsNullOrWhiteSpace($desktop) -and [IO.Directory]::Exists($desktop)) { return $desktop }
    return ([IO.Path]::GetTempPath()).TrimEnd('\')
}

function New-W360ReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][ValidateSet('scan', 'remove', 'verify', 'task', 'help')][string]$Kind
    )

    $fullDirectory = [IO.Path]::GetFullPath($Directory)
    if (-not [IO.Directory]::Exists($fullDirectory)) {
        throw "Report directory does not exist: $fullDirectory"
    }
    $extension = if ($Kind -ieq 'help') { '.txt' } else { '.json' }
    $name = '360-cleanup-{0}-{1}-{2}{3}' -f $Kind.ToLowerInvariant(),
        (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture),
        [Guid]::NewGuid().ToString('N').Substring(0, 8), $extension
    return [IO.Path]::Combine($fullDirectory, $name)
}

function Read-W360JsonBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $info = New-Object IO.FileInfo($Path)
    if (-not $info.Exists) { throw "JSON file was not found: $Path" }
    if ($info.Length -gt 67108864) { throw "JSON file is too large: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $start, $bytes.Length - $start)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON file is empty: $Path" }
    $value = $text | ConvertFrom-Json -ErrorAction Stop
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha256.Dispose() }
    return [pscustomobject]@{ Value = $value; Hash = $hash }
}

function Read-W360JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Read-W360JsonBytes -Path $Path).Value
}

function Get-W360FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-W360CoverageIssueList {
    param([AllowNull()][object]$Coverage)

    foreach ($issue in @(Get-W360ArrayProperty -Object $Coverage -Name 'Issues')) {
        $area = Get-W360StringProperty -Object $issue -Name 'Area'
        $areaKey = 'Coverage.' + $area
        $areaText = if ($area -match '^[A-Za-z]+$' -and $script:W360Strings.ContainsKey($areaKey)) {
            Get-W360Text -Key $areaKey
        }
        else {
            Get-W360Text -Key 'Coverage.Other' -Arguments @($area)
        }
        [pscustomobject]@{
            Area     = $area
            AreaText = $areaText
            Target   = Get-W360StringProperty -Object $issue -Name 'Target'
            Detail   = Get-W360StringProperty -Object $issue -Name 'Detail'
            Text     = Get-W360Text -Key 'Coverage.IssueText' -Arguments @($areaText)
        }
    }
}

function Get-W360CoverageComplete {
    param([AllowNull()][object]$Coverage)

    if ($null -eq $Coverage -or -not (Test-W360HasProperty -Object $Coverage -Name 'Complete')) { return $null }
    $complete = ConvertTo-W360Bool (Get-W360PropertyValue -Object $Coverage -Name 'Complete')
    if ($complete -and @(Get-W360ArrayProperty -Object $Coverage -Name 'Issues').Count -gt 0) { return $false }
    return $complete
}

function Get-W360ScanOutcome {
    param(
        [AllowNull()][object]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$ReportPath,
        [switch]$Cancelled,
        [AllowNull()][AllowEmptyCollection()][object[]]$StdoutLines = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$StderrLines = @()
    )

    $outcome = [pscustomobject]@{
        State           = ''
        Report          = $null
        ReportPath      = $ReportPath
        ReportHash      = ''
        Findings        = @()
        Coverage        = $null
        CoverageComplete = $null
        CoverageIssues  = @()
        SelectableCount = 0
        ReviewCount     = 0
        DeletableGroupCount = 0
        # Get-W360EffectiveDeletableIds of Findings, worked out once for the window and the agent summary.
        EffectiveDeletable = $null
        Headline        = ''
        Detail          = ''
        ErrorText       = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines
    }
    $code = ConvertTo-W360NullableInt64 -Value $ExitCode

    if ($Cancelled) {
        $outcome.State = 'Cancelled'
        $outcome.Headline = Get-W360Text -Key 'Scan.Cancelled.Headline'
        $outcome.Detail = Get-W360Text -Key 'Scan.Cancelled.Detail'
        return $outcome
    }
    if ($null -eq $code -or $code -ne 0) {
        $shownCode = if ($null -eq $code) { Get-W360Text -Key 'Common.Unknown' } else { [string]$code }
        $outcome.State = 'Failed'
        $outcome.Headline = Get-W360Text -Key 'Scan.Failed.Headline'
        $outcome.Detail = Get-W360Text -Key 'Scan.Failed.ExitCode' -Arguments @($shownCode)
        $outcome.ErrorText = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines -IncludeStdout
        return $outcome
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not [IO.File]::Exists($ReportPath)) {
        $outcome.State = 'Failed'
        $outcome.Headline = Get-W360Text -Key 'Scan.Failed.Headline'
        $outcome.Detail = Get-W360Text -Key 'Scan.Failed.NoReport'
        $outcome.ErrorText = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines -IncludeStdout
        return $outcome
    }

    $problem = ''
    $report = $null
    try {
        $read = Read-W360JsonBytes -Path $ReportPath
        $report = $read.Value
        $outcome.ReportHash = $read.Hash
        if ($null -eq $report -or $report -is [System.Array]) { $problem = 'not a JSON object' }
        elseif ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $report -Name 'SchemaVersion')) -ne 2) { $problem = 'SchemaVersion is not 2' }
        elseif ((Get-W360StringProperty -Object $report -Name 'Mode') -cne 'Scan') { $problem = 'Mode is not Scan' }
        elseif (Test-W360NullProperty -Object $report -Name 'Findings') { $problem = 'Findings are missing' }
        elseif (Test-W360NullProperty -Object $report -Name 'ApprovalContext') { $problem = 'ApprovalContext is missing' }
    }
    catch { $problem = $_.Exception.Message }
    if ($problem) {
        $outcome.State = 'InvalidReport'
        $outcome.ReportHash = ''
        $outcome.Headline = Get-W360Text -Key 'Scan.Invalid.Headline'
        $outcome.Detail = Get-W360Text -Key 'Scan.Invalid.Detail'
        # The technical reason stays available for More info and the help summary, not on the page itself.
        $outcome.ErrorText = (@($problem, $outcome.ErrorText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
        return $outcome
    }

    $findings = @(Get-W360ArrayProperty -Object $report -Name 'Findings')
    $coverage = Get-W360PropertyValue -Object $report -Name 'ScanCoverage'
    $coverageComplete = Get-W360CoverageComplete -Coverage $coverage
    # Counts and the headline follow the effectively deletable set: an item that can never pass the selection check
    # in this check result is counted as kept.
    $effective = Get-W360EffectiveDeletableIds -Findings $findings
    $selectableCount = @($findings | Where-Object { Test-W360FindingDeletable -Finding $_ -Effective $effective }).Count
    $outcome.EffectiveDeletable = $effective
    $outcome.Report = $report
    $outcome.Findings = $findings
    $outcome.Coverage = $coverage
    $outcome.CoverageComplete = $coverageComplete
    $outcome.CoverageIssues = @(Get-W360CoverageIssueList -Coverage $coverage)
    $outcome.SelectableCount = $selectableCount
    $outcome.ReviewCount = $findings.Count - $selectableCount

    if ($findings.Count -eq 0) {
        if ($coverageComplete -eq $false) {
            $outcome.State = 'NoMatchesIncomplete'
            $outcome.Headline = Get-W360Text -Key 'Scan.NoMatchesIncomplete.Headline'
            $outcome.Detail = Get-W360Text -Key 'Scan.NoMatchesIncomplete.Detail'
        }
        else {
            $outcome.State = 'NoMatches'
            $outcome.Headline = Get-W360Text -Key 'Scan.NoMatches.Headline'
            $outcome.Detail = Get-W360Text -Key 'Scan.NoMatches.Detail'
        }
        return $outcome
    }

    # The headline counts products (groups) with at least one deletable item; the banner covers incomplete checks.
    $outcome.State = 'Findings'
    $outcome.DeletableGroupCount = @(Get-W360FindingGroups -Findings $findings -Effective $effective | Where-Object { [int]$_.SelectableCount -gt 0 }).Count
    if ($outcome.DeletableGroupCount -gt 0) {
        $outcome.Headline = Get-W360Text -Key 'Scan.Findings.Headline' -Arguments @($outcome.DeletableGroupCount)
        $outcome.Detail = Get-W360Text -Key 'Scan.Findings.Detail'
    }
    else {
        $outcome.Headline = Get-W360Text -Key 'Scan.FindingsKeepOnly.Headline'
        $outcome.Detail = Get-W360Text -Key 'Scan.FindingsKeepOnly.Detail'
    }
    return $outcome
}

function Get-W360ActionText {
    param([AllowNull()][string]$Action)

    if (-not [string]::IsNullOrWhiteSpace($Action) -and $Action -match '^[A-Za-z]+$' -and
        $script:W360Strings.ContainsKey('Action.' + $Action)) {
        return (Get-W360Text -Key ('Action.' + $Action))
    }
    return (Get-W360Text -Key 'Action.Other' -Arguments @([string]$Action))
}

function Get-W360ActionResultText {
    param([AllowNull()][string]$Result)

    if (-not [string]::IsNullOrWhiteSpace($Result) -and $Result -match '^[A-Za-z]+$' -and
        $script:W360Strings.ContainsKey('Result.' + $Result)) {
        return (Get-W360Text -Key ('Result.' + $Result))
    }
    return (Get-W360Text -Key 'Result.Other' -Arguments @([string]$Result))
}

# Plain name of a problem target: the selected finding it belongs to (exact target, "key :: value", task path or
# process executable first, then the deepest selected folder that contains it), otherwise a plain kind name taken
# from the action ("a background service", "some files"). Raw targets stay in the Details window.
function Get-W360RemoveProblemDisplayName {
    param(
        [AllowNull()][AllowEmptyString()][string]$Target,
        [AllowNull()][AllowEmptyCollection()][object[]]$SelectedFindings,
        [AllowNull()][AllowEmptyString()][string]$Action = ''
    )

    $kindKey = switch -Regex ([string]$Action) {
        '^DeleteService$' { 'Name.Problem.Service'; break }
        '^DeleteTask$' { 'Name.Problem.Task'; break }
        '^(StopProcess|StopModuleHolder)$' { 'Name.Problem.Process'; break }
        '^DeleteRegistry(Value|Key)$' { 'Name.Problem.Registry'; break }
        '^RunVendorUninstaller$' { 'Name.Problem.Uninstaller'; break }
        '^(DeletePath|DeletePathRetry|DeletePathForceRetry|RepairPathAcl|VerifyPathRemoval|PostVendorPathPreflight|MeasureRemoval)$' { 'Name.Problem.Path'; break }
        default { 'Name.Problem.Other' }
    }
    $text = ([string]$Target).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return (Get-W360Text -Key $kindKey) }
    $findings = @(Get-W360Items -Value $SelectedFindings)
    foreach ($finding in $findings) {
        $findingTarget = Get-W360StringProperty -Object $finding -Name 'Target'
        $valueName = Get-W360StringProperty -Object $finding -Name 'ValueName'
        $candidates = @($findingTarget)
        if (-not [string]::IsNullOrEmpty($valueName)) {
            $candidates += @(($findingTarget + ' :: ' + $valueName), ($valueName + $findingTarget), $valueName)
        }
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate.Trim().Equals($text, [StringComparison]::OrdinalIgnoreCase)) {
                return (Get-W360FindingDisplayName -Finding $finding)
            }
        }
    }
    $best = $null
    $bestLength = -1
    foreach ($finding in $findings) {
        $root = ConvertTo-W360NormalPath -Path (Get-W360StringProperty -Object $finding -Name 'Target')
        if (-not $root -or -not (Test-W360IsUnderPath -Candidate $text -Root $root)) { continue }
        if ($root.Length -gt $bestLength) { $best = $finding; $bestLength = $root.Length }
    }
    if ($null -ne $best) { return (Get-W360FindingDisplayName -Finding $best) }
    return (Get-W360Text -Key $kindKey)
}

function Get-W360RemoveProblemList {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Actions,
        [AllowNull()][AllowEmptyCollection()][object[]]$SelectedFindings = @()
    )

    $lastByTarget = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $index = 0
    foreach ($action in @(Get-W360Items -Value $Actions)) {
        $target = Get-W360StringProperty -Object $action -Name 'Target'
        $key = if ([string]::IsNullOrWhiteSpace($target)) {
            (Get-W360StringProperty -Object $action -Name 'Action') + '#' + $index
        }
        else { $target.Trim() }
        $lastByTarget[$key] = [pscustomobject]@{ Action = $action; Index = $index }
        $index++
    }

    foreach ($entry in @($lastByTarget.Values | Sort-Object -Property Index)) {
        $action = $entry.Action
        $actionName = Get-W360StringProperty -Object $action -Name 'Action'
        $result = Get-W360StringProperty -Object $action -Name 'Result'
        if (@('Failed', 'Skipped', 'Pending', 'PendingRemoval', 'RetryRequired') -notcontains $result) { continue }
        $detail = Get-W360StringProperty -Object $action -Name 'Detail'
        $reasonCode = ''
        $codeMatch = [regex]::Match($detail, '^\s*ReasonCode=([A-Za-z]+);')
        if ($codeMatch.Success) { $reasonCode = $codeMatch.Groups[1].Value }

        $lockSkip = $actionName -eq 'DeletePathRetry' -and $result -eq 'Skipped' -and
            ($detail -match 'held by a normal or system process' -or $detail -match 'Still locked')
        $holderSkip = $actionName -eq 'StopModuleHolder' -and $result -eq 'Skipped'
        $servicePending = $actionName -eq 'DeleteService' -and $result -eq 'PendingRemoval'
        $reasonKey = ''
        if ($lockSkip -or $holderSkip) { $reasonKey = 'RemoveReason.Locked' }
        elseif ($servicePending) { $reasonKey = 'RemoveReason.ServicePendingRemoval' }
        elseif ($reasonCode -and $script:W360Strings.ContainsKey('RemoveReason.' + $reasonCode) -and
            @('AccessDenied', 'DeleteFailed', 'ReparsePoint', 'UnknownInspectionError', 'VendorUninstallerPending',
                'PostVendorIdentityUnreadable', 'PostVendorIdentityChanged', 'AclRepairFailed') -contains $reasonCode) {
            $reasonKey = 'RemoveReason.' + $reasonCode
        }
        elseif ($actionName -eq 'RunVendorUninstaller' -and $result -eq 'Pending') { $reasonKey = 'RemoveReason.VendorUninstallerPending' }
        elseif ($actionName -eq 'RunVendorUninstaller' -and $result -eq 'Failed') { $reasonKey = 'RemoveReason.VendorUninstallerFailed' }
        elseif ($actionName -eq 'StopProcess' -and $result -eq 'Skipped' -and $detail -match 'already exited') { $reasonKey = 'RemoveReason.ProcessAlreadyExited' }
        elseif ($result -eq 'Failed') { $reasonKey = 'RemoveReason.GenericFailed' }
        elseif ($result -eq 'Skipped') { $reasonKey = 'RemoveReason.GenericSkipped' }
        elseif ($result -eq 'RetryRequired') { $reasonKey = 'RemoveReason.GenericRetry' }
        elseif ($result -eq 'PendingRemoval') { $reasonKey = 'RemoveReason.ServicePendingRemoval' }
        else { $reasonKey = 'RemoveReason.GenericPending' }

        $problemTarget = Get-W360StringProperty -Object $action -Name 'Target'
        [pscustomobject]@{
            Target         = $problemTarget
            DisplayName    = Get-W360RemoveProblemDisplayName -Target $problemTarget -SelectedFindings $SelectedFindings -Action $actionName
            Action         = $actionName
            Result         = $result
            ReasonCode     = $reasonCode
            ActionText     = Get-W360ActionText -Action $actionName
            ResultText     = Get-W360ActionResultText -Result $result
            ReasonText     = Get-W360Text -Key $reasonKey
            RestartMayHelp = [bool]($lockSkip -or $holderSkip -or $servicePending)
            RawDetail      = $detail
        }
    }
}

function Get-W360RemoveOutcome {
    param(
        [AllowNull()][object]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$ReportPath,
        [AllowNull()][AllowEmptyString()][string]$ExpectedApprovedReportHash,
        [AllowNull()][AllowEmptyCollection()][object[]]$Events = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$StdoutLines = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$StderrLines = @(),
        # The findings the user selected (Plan.SelectedFindings); only used to give problems a plain name.
        [AllowNull()][AllowEmptyCollection()][object[]]$SelectedFindings = @()
    )

    $code = ConvertTo-W360NullableInt64 -Value $ExitCode
    $outcome = [pscustomobject]@{
        State      = ''
        Headline   = ''
        Detail     = ''
        Problems   = @()
        Stats      = $null
        CountsText = ''
        NextSteps  = @()
        Report     = $null
        ReportPath = $ReportPath
        ReportIssue = ''
        ExitCode   = $code
        ErrorText  = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines -IncludeStdout
        # Kept items the check right after deleting could not see as still there (null when not recorded), and
        # whether an uninstaller that came with 360 ran. Either one means unticked items may have changed.
        PreservedNotConfirmedPresent = $null
        VendorUninstallerRan         = $false
    }
    # Every next step names the exact button text the user has to look for.
    $verifyTaskButton = Get-W360Text -Key 'Ui.Button.VerifyTask'

    $phases = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $errorDetail = ''
    foreach ($progressEvent in @(Get-W360Items -Value $Events)) {
        $phase = Get-W360StringProperty -Object $progressEvent -Name 'Phase'
        if ($phase) { [void]$phases.Add($phase) }
        if ($phase -eq 'Error') { $errorDetail = Get-W360StringProperty -Object $progressEvent -Name 'Detail' }
    }

    $report = $null
    $issue = ''
    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not [IO.File]::Exists($ReportPath)) { $issue = 'Missing' }
    else {
        try {
            $report = Read-W360JsonFile -Path $ReportPath
            if ($null -eq $report -or $report -is [System.Array]) { $issue = 'NotAnObject' }
            elseif ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $report -Name 'SchemaVersion')) -ne 2) { $issue = 'SchemaVersion' }
            elseif ((Get-W360StringProperty -Object $report -Name 'Mode') -cne 'Remove') { $issue = 'Mode' }
            elseif (Test-W360NullProperty -Object $report -Name 'Summary') { $issue = 'Summary' }
            elseif (Test-W360NullProperty -Object $report -Name 'Actions') { $issue = 'Actions' }
            elseif ([string]$ExpectedApprovedReportHash -notmatch '^[0-9A-Fa-f]{64}$' -or
                -not (Get-W360StringProperty -Object $report -Name 'ApprovedReportHash').Equals(
                    [string]$ExpectedApprovedReportHash, [StringComparison]::OrdinalIgnoreCase)) { $issue = 'HashMismatch' }
        }
        catch { $issue = 'Unreadable' }
    }

    if ($issue) {
        $outcome.ReportIssue = $issue
        $started = $false
        foreach ($phase in $script:W360RemoveStartedPhases) {
            if ($phases.Contains($phase)) { $started = $true; break }
        }
        if ($phases.Contains('ElevationCancelled')) {
            $outcome.State = 'NotStarted'
            $outcome.Headline = Get-W360Text -Key 'Remove.NotStarted.Headline'
            $outcome.Detail = Get-W360Text -Key 'Remove.NotStarted.Cancelled'
            $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.NotStarted')
        }
        elseif ($null -ne $code -and $code -ne 0 -and -not $started) {
            $reason = $errorDetail
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = @(Get-W360TailLines -Lines $StderrLines -Count 1) -join ''
            }
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = Get-W360Text -Key 'Remove.NotStarted.NoReason' -Arguments @($code)
            }
            $outcome.State = 'NotStarted'
            $outcome.Headline = Get-W360Text -Key 'Remove.NotStarted.Headline'
            $outcome.Detail = Get-W360Text -Key 'Remove.NotStarted.Error' -Arguments @($reason.Trim())
            $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.NotStarted')
        }
        else {
            $outcome.State = 'Unknown'
            $outcome.Headline = Get-W360Text -Key 'Remove.Unknown.Headline'
            $outcome.Detail = Get-W360Text -Key 'Remove.Unknown.NoReport'
            # Without a valid report this run never appears on the home page, so point to a new check, not to it.
            $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.RestartRescan')
        }
        return $outcome
    }

    $summary = Get-W360PropertyValue -Object $report -Name 'Summary'
    $problems = @(Get-W360RemoveProblemList -Actions @(Get-W360ArrayProperty -Object $report -Name 'Actions') -SelectedFindings $SelectedFindings)
    $restartProblems = @($problems | Where-Object { $_.RestartMayHelp })
    $otherProblems = @($problems | Where-Object { -not $_.RestartMayHelp })
    $number = { param($Name) ConvertTo-W360Int64 (Get-W360PropertyValue -Object $summary -Name $Name) }
    $remainingSelected = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediateRemainingSelected')
    $rescanComplete = ConvertTo-W360Bool (Get-W360PropertyValue -Object $summary -Name 'ImmediateRescanComplete')
    $mutationBlocked = ConvertTo-W360Bool (Get-W360PropertyValue -Object $summary -Name 'PostVendorMutationBlocked')
    $accountingComplete = ConvertTo-W360Bool (Get-W360PropertyValue -Object $summary -Name 'PathAccountingComplete')

    $outcome.Report = $report
    $outcome.Problems = $problems
    $outcome.Stats = [pscustomobject]@{
        Selected                    = & $number 'SelectedConfirmedFindings'
        Preserved                   = & $number 'UnselectedConfirmedFindings'
        FilesRemoved                = & $number 'FilesRemoved'
        DirectoriesRemoved          = & $number 'DirectoriesRemoved'
        LogicalSize                 = Get-W360StringProperty -Object $summary -Name 'LogicalSizeRemoved'
        LogicalBytes                = & $number 'LogicalBytesRemoved'
        LogicalSizeNote             = Get-W360Text -Key 'Stats.LogicalSizeNote'
        PathAccountingComplete      = [bool]$accountingComplete
        PathAccountingNote          = $(if ($accountingComplete) { '' } else { Get-W360Text -Key 'Stats.MinimumNote' })
        ServicesRemoved             = & $number 'ServicesRemoved'
        ServicesPendingRemoval      = & $number 'ServicesPendingRemoval'
        ScheduledTasksRemoved       = & $number 'ScheduledTasksRemoved'
        RegistryItemsRemoved        = (& $number 'RegistryKeysRemoved') + (& $number 'RegistryValuesRemoved')
        ProcessesStopped            = & $number 'ProcessesStopped'
        VendorUninstallersSucceeded = & $number 'VendorUninstallersSucceeded'
        SkippedActions              = & $number 'SkippedActions'
        FailedActions               = & $number 'FailedActions'
        PendingActions              = & $number 'PendingActions'
        SelectedConfirmedAbsent     = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediateSelectedConfirmedAbsent')
        SelectedStillPresent        = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediateSelectedStillPresent')
        SelectedUnknown             = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediateSelectedUnknown')
    }
    $preservedNotPresent = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediatePreservedNotConfirmedPresent')
    $outcome.PreservedNotConfirmedPresent = $preservedNotPresent
    $outcome.VendorUninstallerRan = [bool](((& $number 'VendorUninstallersSucceeded') + (& $number 'VendorUninstallersPending') + (& $number 'VendorUninstallersFailed')) -gt 0 -or
        @(Get-W360ArrayProperty -Object $report -Name 'Actions' | Where-Object {
            (Get-W360StringProperty -Object $_ -Name 'Action') -eq 'RunVendorUninstaller'
        }).Count -gt 0)

    $unknownStep = Get-W360Text -Key 'Remove.Next.Unknown' -Arguments @($verifyTaskButton)
    if (-not $rescanComplete -or $mutationBlocked -or $null -eq $remainingSelected) {
        $outcome.State = 'Unknown'
        $outcome.Headline = Get-W360Text -Key 'Remove.Unknown.Headline'
        $outcome.Detail = Get-W360Text -Key 'Remove.Unknown.RescanBlocked'
        $outcome.NextSteps = @($unknownStep)
        return $outcome
    }

    $unresolvedPaths = & $number 'UnresolvedPathTargets'
    $partial = (& $number 'FailedActions') -gt 0 -or (& $number 'VendorUninstallersFailed') -gt 0 -or
        ($remainingSelected -gt 0 -and $otherProblems.Count -gt 0) -or
        ($unresolvedPaths -gt 0 -and ($otherProblems.Count -gt 0 -or $restartProblems.Count -eq 0)) -or
        (& $number 'AclRepairFailures') -gt 0 -or -not $accountingComplete
    $needsRestart = -not $partial -and ((& $number 'ServicesPendingRemoval') -gt 0 -or
        (& $number 'VendorUninstallersPending') -gt 0 -or $restartProblems.Count -gt 0 -or $remainingSelected -gt 0)

    # Selected targets the immediate read-only probes could not read are not proven removed.
    $selectedUnknown = ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $summary -Name 'ImmediateSelectedUnknown')
    $partialByExitCode = $false
    if ($partial) {
        $outcome.State = 'Partial'
        $outcome.Headline = Get-W360Text -Key 'Remove.Partial.Headline'
        $outcome.Detail = Get-W360Text -Key 'Remove.Partial.Detail'
    }
    elseif ($null -ne $selectedUnknown -and $selectedUnknown -gt 0) {
        $outcome.State = 'Unknown'
        $outcome.Headline = Get-W360Text -Key 'Remove.Unknown.Headline'
        $outcome.Detail = Get-W360Text -Key 'Remove.Unknown.SelectedUnknown' -Arguments @($selectedUnknown)
        $outcome.NextSteps = @($unknownStep)
        return $outcome
    }
    elseif ($needsRestart) {
        $outcome.State = 'NeedsRestart'
        $outcome.Headline = Get-W360Text -Key 'Remove.NeedsRestart.Headline'
        $outcome.Detail = Get-W360Text -Key 'Remove.NeedsRestart.Detail'
    }
    elseif ($null -eq $code -or $code -ne 0) {
        $shownCode = if ($null -eq $code) { Get-W360Text -Key 'Common.Unknown' } else { [string]$code }
        $outcome.State = 'Partial'
        $outcome.Headline = Get-W360Text -Key 'Remove.Partial.Headline'
        $outcome.Detail = Get-W360Text -Key 'Remove.Partial.ExitCode' -Arguments @($shownCode)
        $partialByExitCode = $true
    }
    else {
        $outcome.State = 'Completed'
        $outcome.Headline = Get-W360Text -Key 'Remove.Completed.Headline'
        # Never claim unticked items were untouched when kept items changed or a vendor uninstaller ran. Only an
        # uninstaller that actually ran is named as a possible cause.
        if ($null -ne $preservedNotPresent -and $preservedNotPresent -gt 0) {
            $affectedKey = if ([bool]$outcome.VendorUninstallerRan) { 'Remove.Completed.PreservedAffected' } else { 'Remove.Completed.PreservedUnconfirmed' }
            $outcome.Detail = Get-W360Text -Key $affectedKey -Arguments @($preservedNotPresent)
        }
        elseif ([bool]$outcome.VendorUninstallerRan) { $outcome.Detail = Get-W360Text -Key 'Remove.Completed.VendorRan' }
        else { $outcome.Detail = Get-W360Text -Key 'Remove.Completed.Detail' -Arguments @($outcome.Stats.Selected) }
    }
    # The one-line counts back only a finished result: the check right after deleting completed and recorded all
    # three numbers, and the page is Completed or Partial. Unknown, restart-needed and exit-code results show none,
    # so "0 not deleted" can never sit under a headline that says the result is not certain.
    if ((@('Completed', 'Partial') -contains $outcome.State) -and -not $partialByExitCode -and
        $null -ne $outcome.Stats.SelectedConfirmedAbsent -and $null -ne $outcome.Stats.SelectedStillPresent -and
        $null -ne $outcome.Stats.SelectedUnknown) {
        $outcome.CountsText = Get-W360Text -Key 'Ui.Remove.Counts' -Arguments @(
            $outcome.Stats.SelectedConfirmedAbsent, $outcome.Stats.SelectedStillPresent, $outcome.Stats.SelectedUnknown)
    }
    switch ($outcome.State) {
        'Partial' {
            $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.Partial' -Arguments @($verifyTaskButton, (Get-W360Text -Key 'Ui.Button.HelpSummary')))
        }
        'NeedsRestart' { $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.Restart' -Arguments @($verifyTaskButton)) }
        default {
            # Completed does not need a restart; the restart-and-check step is a recommendation only.
            $outcome.NextSteps = @(Get-W360Text -Key 'Remove.Next.CompletedVerify' -Arguments @($verifyTaskButton))
        }
    }
    return $outcome
}

# The short problem list of the remove result page: problems with the same plain name and reason are one line
# ('"name": reason (N places)'), the first Limit lines are shown plus a "N more" line; the Details window lists
# every single problem.
function Get-W360RemoveProblemLines {
    param(
        [AllowNull()][object]$Outcome,
        [ValidateRange(1, 100)][int]$Limit = 5
    )

    $groups = New-Object System.Collections.ArrayList
    $groupByKey = @{}
    foreach ($problem in @(Get-W360ArrayProperty -Object $Outcome -Name 'Problems')) {
        $name = Get-W360StringProperty -Object $problem -Name 'DisplayName'
        $reason = Get-W360StringProperty -Object $problem -Name 'ReasonText'
        $key = $name + [char]0 + $reason
        if (-not $groupByKey.ContainsKey($key)) {
            $entry = [pscustomobject]@{ Name = $name; Reason = $reason; Count = 0 }
            $groupByKey[$key] = $entry
            [void]$groups.Add($entry)
        }
        $groupByKey[$key].Count++
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($group in ($groups | Select-Object -First $Limit)) {
        if ([int]$group.Count -gt 1) {
            $lines.Add((Get-W360Text -Key 'Ui.Remove.ProblemLineCount' -Arguments @($group.Name, $group.Reason, $group.Count)))
        }
        else {
            $lines.Add((Get-W360Text -Key 'Ui.Remove.ProblemLine' -Arguments @($group.Name, $group.Reason)))
        }
    }
    if ($groups.Count -gt $Limit) { $lines.Add((Get-W360Text -Key 'Ui.Remove.MoreProblems' -Arguments @($groups.Count - $Limit))) }
    return [string[]]$lines.ToArray()
}

# Headline tone of any scan, remove or verify outcome: Success, Warning, Error, Neutral or Text.
# Failure, unknown, incomplete, restart-needed and cancelled results are never Success, and neither is a finished
# result where items the user kept are gone or may have changed.
function Get-W360OutcomeTone {
    param([AllowNull()][object]$Outcome)

    $state = Get-W360StringProperty -Object $Outcome -Name 'State'
    switch -CaseSensitive ($state) {
        'TaskCompleted' {
            if ((Get-W360PropertyValue -Object $Outcome -Name 'CoverageComplete') -eq $false) { return 'Warning' }
            if ((ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedGoneCount')) -gt 0) { return 'Warning' }
            if ((ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedChangedCount')) -gt 0) { return 'Warning' }
            if ((ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedUnknownCount')) -gt 0) { return 'Warning' }
            return 'Success'
        }
        'GlobalClean' { return 'Success' }
        'GlobalKeptOnly' { return 'Text' }
        'TaskCompletedWithNew' { return 'Warning' }
        'GlobalRemaining' { return 'Warning' }
        'GlobalIncomplete' { return 'Warning' }
        'TaskUnavailable' { return 'Warning' }
        'TaskUnknown' { return 'Warning' }
        'TaskRemaining' { return 'Error' }
        'Completed' {
            if ((ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedNotConfirmedPresent')) -gt 0) { return 'Warning' }
            if (ConvertTo-W360Bool (Get-W360PropertyValue -Object $Outcome -Name 'VendorUninstallerRan')) { return 'Warning' }
            return 'Success'
        }
        'NeedsRestart' { return 'Warning' }
        'Partial' { return 'Error' }
        'Unknown' { return 'Warning' }
        'NotStarted' { return 'Neutral' }
        'NoMatches' { return 'Success' }
        'NoMatchesIncomplete' { return 'Warning' }
        'Findings' { return 'Text' }
        'Cancelled' { return 'Neutral' }
        'Failed' { return 'Error' }
        'InvalidReport' { return 'Error' }
    }
    return 'Warning'
}

function Get-W360VerifyStateText {
    param(
        [string]$Category,
        [AllowNull()][string]$State
    )

    $key = 'VerifyState.' + $Category + '.' + $State
    if ($Category -match '^[A-Za-z]+$' -and $State -match '^[A-Za-z]+$' -and $script:W360Strings.ContainsKey($key)) {
        return (Get-W360Text -Key $key)
    }
    return (Get-W360Text -Key 'VerifyState.Other' -Arguments @([string]$State))
}

function ConvertTo-W360VerifyItem {
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory = $true)][string]$Category,
        [AllowNull()][string]$StateText
    )

    $state = Get-W360StringProperty -Object $Item -Name 'State'
    $detailCode = Get-W360StringProperty -Object $Item -Name 'DetailCode'
    $rawDetail = Get-W360StringProperty -Object $Item -Name 'Detail'
    $detail = $rawDetail
    if ($detailCode -match '^[A-Za-z]+$' -and $script:W360Strings.ContainsKey('DetailCode.' + $detailCode)) {
        $detail = Get-W360Text -Key ('DetailCode.' + $detailCode)
    }
    if ([string]::IsNullOrWhiteSpace($StateText)) { $StateText = Get-W360VerifyStateText -Category $Category -State $state }
    return [pscustomobject]@{
        Category    = $Category
        State       = $state
        DisplayName = Get-W360FindingDisplayName -Finding $Item
        KindText    = Get-W360FindingKindText -Finding $Item
        StateText   = $StateText
        Target      = Get-W360StringProperty -Object $Item -Name 'Target'
        Detail      = $detail
        DetailCode  = $detailCode
        RawDetail   = $rawDetail
        ProductName = (Get-W360ProductInfo -ProductKey (Get-W360StringProperty -Object $Item -Name 'ProductKey')).DisplayName
    }
}

function Get-W360VerifyOutcome {
    param(
        [AllowNull()][object]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$ReportPath,
        [switch]$Cancelled,
        [AllowNull()][AllowEmptyCollection()][object[]]$StdoutLines = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$StderrLines = @()
    )

    $code = ConvertTo-W360NullableInt64 -Value $ExitCode
    $sectionOrder = @('SelectedRemaining', 'Preserved', 'NewOrChanged', 'Unknown')
    $outcome = [pscustomobject]@{
        State            = ''
        Headline         = ''
        Detail           = ''
        Sections         = [pscustomobject]@{ SelectedRemaining = @(); Preserved = @(); PreservedGone = @(); NewOrChanged = @(); Unknown = @(); CurrentIdentified = @(); CurrentKept = @() }
        SectionInfo      = @()
        # Additive: the non-empty sections in the order the result grid shows them ({Key; Title; Count; Items}).
        GridSections     = @()
        Cleared          = @()
        GlobalCounts     = $null
        CoverageIssues   = @()
        CoverageComplete = $null
        NextSteps        = @()
        Report           = $null
        ReportPath       = $ReportPath
        ExitCode         = $code
        TaskStatus       = ''
        # Kept-item anomalies do not fail the selected task, but a finished result with any is never green.
        PreservedGoneCount = 0
        PreservedChangedCount = 0
        PreservedUnknownCount = 0
        ErrorText        = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines
    }
    $setSectionInfo = {
        $outcome.SectionInfo = @($sectionOrder | ForEach-Object {
            [pscustomobject]@{
                Key   = $_
                Title = Get-W360Text -Key ('Verify.Section.' + $_)
                Count = @($outcome.Sections.$_).Count
            }
        })
    }
    $setGridSections = {
        param([string[]]$Keys)
        $outcome.GridSections = @(foreach ($sectionKey in $Keys) {
            $sectionItems = @(if ($sectionKey -eq 'Cleared') { $outcome.Cleared } else { $outcome.Sections.$sectionKey })
            if ($sectionItems.Count -eq 0) { continue }
            [pscustomobject]@{
                Key   = $sectionKey
                Title = Get-W360Text -Key ('Verify.Section.' + $sectionKey)
                Count = $sectionItems.Count
                Items = $sectionItems
            }
        })
    }
    & $setSectionInfo
    $retryStep = Get-W360Text -Key 'Verify.Next.Retry' -Arguments @((Get-W360Text -Key 'Ui.Button.HelpSummary'))
    $rescanButton = Get-W360Text -Key 'Ui.Button.Rescan'

    if ($Cancelled) {
        $outcome.State = 'Cancelled'
        $outcome.Headline = Get-W360Text -Key 'Verify.Cancelled.Headline'
        $outcome.Detail = Get-W360Text -Key 'Verify.Cancelled.Detail'
        $outcome.NextSteps = @($retryStep)
        return $outcome
    }
    # The code stays a 64-bit number: Windows reports some ends (for example 0xC000013A) as values beyond Int32.
    if ($null -eq $code -or ($code -ne 0 -and $code -ne 2 -and $code -ne 3 -and $code -ne 4)) {
        $shownCode = if ($null -eq $code) { Get-W360Text -Key 'Common.Unknown' } else { [string]$code }
        $outcome.State = 'Failed'
        $outcome.Headline = Get-W360Text -Key 'Verify.Failed.Headline'
        $outcome.Detail = Get-W360Text -Key 'Verify.Failed.ExitCode' -Arguments @($shownCode)
        $outcome.ErrorText = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines -IncludeStdout
        $outcome.NextSteps = @($retryStep)
        return $outcome
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not [IO.File]::Exists($ReportPath)) {
        $outcome.State = 'Failed'
        $outcome.Headline = Get-W360Text -Key 'Verify.Failed.Headline'
        $outcome.Detail = Get-W360Text -Key 'Verify.Failed.NoReport'
        $outcome.ErrorText = Get-W360ErrorText -StderrLines $StderrLines -StdoutLines $StdoutLines -IncludeStdout
        $outcome.NextSteps = @($retryStep)
        return $outcome
    }

    $problem = ''
    $report = $null
    try {
        $report = Read-W360JsonFile -Path $ReportPath
        if ($null -eq $report -or $report -is [System.Array]) { $problem = 'not a JSON object' }
        elseif ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $report -Name 'SchemaVersion')) -ne 2) { $problem = 'SchemaVersion is not 2' }
        elseif ((Get-W360StringProperty -Object $report -Name 'Mode') -cne 'Verify') { $problem = 'Mode is not Verify' }
        elseif (Test-W360NullProperty -Object $report -Name 'Findings') { $problem = 'Findings are missing' }
    }
    catch { $problem = $_.Exception.Message }
    if ($problem) {
        $outcome.State = 'InvalidReport'
        $outcome.Headline = Get-W360Text -Key 'Verify.Invalid.Headline'
        $outcome.Detail = Get-W360Text -Key 'Verify.Invalid.Detail'
        # The technical reason stays available for More info and the help summary, not on the page itself.
        $outcome.ErrorText = (@($problem, $outcome.ErrorText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
        $outcome.NextSteps = @($retryStep)
        return $outcome
    }

    $findings = @(Get-W360ArrayProperty -Object $report -Name 'Findings')
    $coverage = Get-W360PropertyValue -Object $report -Name 'ScanCoverage'
    $coverageComplete = Get-W360CoverageComplete -Coverage $coverage
    $coverageIssues = @(Get-W360CoverageIssueList -Coverage $coverage)
    $confirmedFindings = @($findings | Where-Object {
        (Get-W360StringProperty -Object $_ -Name 'Confidence') -eq 'Confirmed' -and
            -not (ConvertTo-W360Bool (Get-W360PropertyValue -Object $_ -Name 'Offline'))
    })
    $selectableCount = @($findings | Where-Object { Test-W360FindingSelectable -Finding $_ }).Count
    $outcome.Report = $report
    $outcome.CoverageComplete = $coverageComplete
    $outcome.CoverageIssues = $coverageIssues
    $outcome.GlobalCounts = [pscustomobject]@{
        TotalFindings      = $findings.Count
        ConfirmedFindings  = $confirmedFindings.Count
        SelectableFindings = $selectableCount
        ReviewOnlyFindings = $findings.Count - $confirmedFindings.Count
        CoverageComplete   = $coverageComplete
    }

    $unknownItems = New-Object System.Collections.ArrayList
    foreach ($issue in $coverageIssues) {
        [void]$unknownItems.Add([pscustomobject]@{
            Category    = 'Coverage'
            State       = 'Incomplete'
            DisplayName = $issue.AreaText
            KindText    = Get-W360Text -Key 'Verify.CoverageKind'
            StateText   = Get-W360Text -Key 'VerifyState.Coverage'
            Target      = $issue.Target
            Detail      = $issue.Detail
            DetailCode  = ''
            RawDetail   = $issue.Detail
            ProductName = ''
        })
    }

    $task = Get-W360PropertyValue -Object $report -Name 'TaskVerification'
    # Items that are never deleted (for example a program that is still installed) are listed with their reason,
    # so a whole-PC result never looks clean while they remain.
    $keptFindings = @($findings | Where-Object {
        (Get-W360StringProperty -Object $_ -Name 'Confidence') -ne 'Confirmed' -or
            (ConvertTo-W360Bool (Get-W360PropertyValue -Object $_ -Name 'Offline'))
    })
    # Without a task record the exit code is the whole-PC result; with an unusable record the core reports 3 for
    # "record unusable", which says nothing about the checks themselves.
    $globalCodeIncomplete = ($null -eq $task -and $code -ne 0)
    $globalState = if ($confirmedFindings.Count -gt 0) { 'GlobalRemaining' }
        elseif ($coverageComplete -eq $false -or $globalCodeIncomplete) { 'GlobalIncomplete' }
        elseif ($keptFindings.Count -gt 0) { 'GlobalKeptOnly' }
        else { 'GlobalClean' }
    $globalDetail = switch ($globalState) {
        'GlobalRemaining' { Get-W360Text -Key 'Verify.GlobalRemaining.Detail' }
        'GlobalIncomplete' { Get-W360Text -Key 'Verify.GlobalIncomplete.Detail' }
        'GlobalKeptOnly' { Get-W360Text -Key 'Verify.GlobalKeptOnly.Detail' }
        default { Get-W360Text -Key 'Verify.GlobalClean.Detail' }
    }
    $globalHeadline = switch ($globalState) {
        'GlobalRemaining' { Get-W360Text -Key 'Verify.GlobalRemaining.Headline' -Arguments @($confirmedFindings.Count) }
        'GlobalKeptOnly' { Get-W360Text -Key 'Verify.GlobalKeptOnly.Headline' -Arguments @($keptFindings.Count) }
        default { Get-W360Text -Key ('Verify.' + $globalState + '.Headline') }
    }
    $globalStep = switch ($globalState) {
        'GlobalRemaining' { Get-W360Text -Key 'Verify.Next.RescanDecide' -Arguments @($rescanButton) }
        'GlobalIncomplete' { Get-W360Text -Key 'Verify.Next.IncompleteRetry' }
        'GlobalKeptOnly' { Get-W360Text -Key 'Verify.Next.KeptOnly' }
        default { Get-W360Text -Key 'Verify.Next.Done' }
    }
    $currentItems = @($confirmedFindings | ForEach-Object {
        ConvertTo-W360VerifyItem -Item $_ -Category 'Current' -StateText (Get-W360Text -Key 'VerifyState.Current.Confirmed')
    })
    $currentKeptItems = @($keptFindings | ForEach-Object {
        $keptStatus = Get-W360FindingStatus -Finding $_
        $keptItem = ConvertTo-W360VerifyItem -Item $_ -Category 'CurrentKept' -StateText $keptStatus.Text
        # The plain "why it is not deleted" explanation is the description of a kept item.
        $keptItem.Detail = $keptStatus.Explanation
        $keptItem
    })
    $globalSectionOrder = @('CurrentIdentified', 'Unknown', 'CurrentKept')

    if ($null -eq $task) {
        $outcome.State = $globalState
        $outcome.Headline = $globalHeadline
        $outcome.Detail = $globalDetail
        $outcome.Sections = [pscustomobject]@{
            SelectedRemaining = @()
            Preserved         = @()
            PreservedGone     = @()
            NewOrChanged      = @()
            Unknown           = @($unknownItems)
            CurrentIdentified = $currentItems
            CurrentKept       = $currentKeptItems
        }
        & $setSectionInfo
        & $setGridSections $globalSectionOrder
        $outcome.NextSteps = @($globalStep)
        return $outcome
    }

    $status = Get-W360StringProperty -Object $task -Name 'Status'
    $outcome.TaskStatus = $status
    if ($status -eq 'Unavailable') {
        $reasonCode = Get-W360StringProperty -Object $task -Name 'UnavailableReason'
        $reasonText = if ($reasonCode -match '^[A-Za-z]+$' -and $script:W360Strings.ContainsKey('Unavailable.' + $reasonCode)) {
            Get-W360Text -Key ('Unavailable.' + $reasonCode)
        }
        else { Get-W360Text -Key 'Unavailable.Other' }
        $outcome.State = 'TaskUnavailable'
        $outcome.Headline = Get-W360Text -Key 'Verify.TaskUnavailable.Headline'
        $outcome.Detail = Get-W360Text -Key 'Verify.TaskUnavailable.Detail' -Arguments @($reasonText, $globalHeadline)
        $outcome.Sections = [pscustomobject]@{
            SelectedRemaining = @()
            Preserved         = @()
            PreservedGone     = @()
            NewOrChanged      = @()
            Unknown           = @($unknownItems)
            CurrentIdentified = $currentItems
            CurrentKept       = $currentKeptItems
        }
        & $setSectionInfo
        & $setGridSections $globalSectionOrder
        $unavailableStep = if ($globalState -eq 'GlobalRemaining') {
            Get-W360Text -Key 'Verify.Next.RescanDecide' -Arguments @($rescanButton)
        }
        else { Get-W360Text -Key 'Verify.Next.Rescan' -Arguments @($rescanButton) }
        $outcome.NextSteps = @($unavailableStep)
        return $outcome
    }

    $selectedItems = @(Get-W360ArrayProperty -Object $task -Name 'Selected')
    $preservedItems = @(Get-W360ArrayProperty -Object $task -Name 'Preserved')
    $newItems = @(Get-W360ArrayProperty -Object $task -Name 'New')

    $cleared = New-Object System.Collections.ArrayList
    $selectedRemaining = New-Object System.Collections.ArrayList
    $newOrChanged = New-Object System.Collections.ArrayList
    $unknownTask = New-Object System.Collections.ArrayList
    $remainingOrChanged = 0
    $unknownCount = 0
    foreach ($item in $selectedItems) {
        $state = Get-W360StringProperty -Object $item -Name 'State'
        switch -CaseSensitive ($state) {
            'Absent' { [void]$cleared.Add((ConvertTo-W360VerifyItem -Item $item -Category 'Selected')) }
            'Remaining' {
                [void]$selectedRemaining.Add((ConvertTo-W360VerifyItem -Item $item -Category 'Selected'))
                $remainingOrChanged++
            }
            'Changed' {
                [void]$newOrChanged.Add((ConvertTo-W360VerifyItem -Item $item -Category 'Selected'))
                $remainingOrChanged++
            }
            default {
                [void]$unknownTask.Add((ConvertTo-W360VerifyItem -Item $item -Category 'Selected'))
                $unknownCount++
            }
        }
    }
    # An uninstaller that came with 360 is named as a possible cause only for kept items of its own product.
    $vendorProductKeys = New-Object System.Collections.Generic.List[string]
    foreach ($item in $selectedItems) {
        if ((Get-W360StringProperty -Object $item -Name 'Kind') -ne 'VendorUninstaller' -and
            (Get-W360StringProperty -Object $item -Name 'RemovalType') -ne 'VendorUninstaller') { continue }
        $vendorKey = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $item -Name 'ProductKey')
        if (-not $vendorProductKeys.Contains($vendorKey)) { $vendorProductKeys.Add($vendorKey) }
    }
    # Every kept item is listed once: still there, gone (its own section, never under "kept"), changed or unknown.
    $preservedSection = New-Object System.Collections.ArrayList
    $preservedGoneSection = New-Object System.Collections.ArrayList
    $preservedGoneByVendor = 0
    foreach ($item in $preservedItems) {
        $state = Get-W360StringProperty -Object $item -Name 'State'
        if ($state -ceq 'Absent') {
            $sameProduct = $vendorProductKeys.Contains((Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $item -Name 'ProductKey')))
            if ($sameProduct) { $preservedGoneByVendor++ }
            $goneText = Get-W360Text -Key $(if ($sameProduct) { 'VerifyState.Preserved.Absent' } else { 'VerifyState.Preserved.AbsentPlain' })
            [void]$preservedGoneSection.Add((ConvertTo-W360VerifyItem -Item $item -Category 'Preserved' -StateText $goneText))
            continue
        }
        $converted = ConvertTo-W360VerifyItem -Item $item -Category 'Preserved'
        if ($state -ceq 'Present') { [void]$preservedSection.Add($converted) }
        elseif ($state -ceq 'Changed') {
            [void]$newOrChanged.Add($converted)
            $outcome.PreservedChangedCount++
        }
        else {
            [void]$unknownTask.Add($converted)
            $outcome.PreservedUnknownCount++
        }
    }
    foreach ($item in $newItems) {
        [void]$newOrChanged.Add((ConvertTo-W360VerifyItem -Item $item -Category 'New'))
    }
    foreach ($item in @($unknownItems)) { [void]$unknownTask.Add($item) }

    $outcome.Cleared = @($cleared)
    $outcome.PreservedGoneCount = $preservedGoneSection.Count
    $outcome.Sections = [pscustomobject]@{
        SelectedRemaining = @($selectedRemaining)
        Preserved         = @($preservedSection)
        PreservedGone     = @($preservedGoneSection)
        NewOrChanged      = @($newOrChanged)
        Unknown           = @($unknownTask)
        CurrentIdentified = @()
        CurrentKept       = @()
    }
    & $setSectionInfo

    # The reported Status and the item states must agree; the worse of the two always wins.
    $effective = 'Completed'
    if ($status -ceq 'Remaining' -or $remainingOrChanged -gt 0) { $effective = 'Remaining' }
    elseif ($status -cne 'Completed' -or $unknownCount -gt 0) { $effective = 'Unknown' }
    elseif ($code -ne 0 -and $code -ne 3 -and $code -ne 4) { $effective = 'Unknown' }
    $counts = Get-W360PropertyValue -Object $task -Name 'Counts'
    $newCount = [Math]::Max((ConvertTo-W360Int64 (Get-W360PropertyValue -Object $counts -Name 'NewConfirmed')), [long]$newItems.Count)
    & $setGridSections @('SelectedRemaining', 'Unknown', 'NewOrChanged', 'PreservedGone', 'Preserved', 'Cleared')

    # Kept anomalies are separate from selected-task completion and are explained on every result page.
    $preservedStates = @($preservedItems | ForEach-Object { Get-W360StringProperty -Object $_ -Name 'State' })
    $preservedAttentionCount = $outcome.PreservedGoneCount + $outcome.PreservedChangedCount + $outcome.PreservedUnknownCount
    $preservedSentences = New-Object System.Collections.Generic.List[string]
    if ($preservedGoneSection.Count -gt 0) {
        $goneKey = if ($preservedGoneByVendor -gt 0) { 'Verify.TaskCompleted.PreservedGone' } else { 'Verify.TaskCompleted.PreservedGonePlain' }
        $preservedSentences.Add((Get-W360Text -Key $goneKey -Arguments @($preservedGoneSection.Count)))
    }
    if ($outcome.PreservedChangedCount -gt 0) {
        $preservedSentences.Add((Get-W360Text -Key 'Verify.TaskCompleted.PreservedChanged' -Arguments @($outcome.PreservedChangedCount)))
    }
    if ($outcome.PreservedUnknownCount -gt 0) {
        $preservedSentences.Add((Get-W360Text -Key 'Verify.TaskCompleted.PreservedUnknown' -Arguments @($outcome.PreservedUnknownCount)))
    }
    if ($preservedStates.Count -gt 0 -and $preservedAttentionCount -eq 0) {
        $preservedSentences.Add((Get-W360Text -Key 'Verify.TaskCompleted.PreservedKept'))
    }
    $preservedSentence = $preservedSentences -join (Get-W360Text -Key 'Common.SentenceSeparator')
    $joinDetail = {
        param([string]$First, [switch]$WarningsOnly)
        if ([string]::IsNullOrWhiteSpace($preservedSentence)) { return $First }
        if ($WarningsOnly -and $preservedAttentionCount -eq 0) { return $First }
        return ($First + (Get-W360Text -Key 'Common.SentenceSeparator') + $preservedSentence)
    }
    $verifyTaskButton = Get-W360Text -Key 'Ui.Button.VerifyTask'
    $helpButton = Get-W360Text -Key 'Ui.Button.HelpSummary'

    switch ($effective) {
        'Remaining' {
            $outcome.State = 'TaskRemaining'
            $outcome.Headline = Get-W360Text -Key 'Verify.TaskRemaining.Headline' -Arguments @($remainingOrChanged)
            $outcome.Detail = & $joinDetail (Get-W360Text -Key 'Verify.TaskRemaining.Detail' -Arguments @($remainingOrChanged)) -WarningsOnly
            $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.RestartIfLocked' -Arguments @($verifyTaskButton, $helpButton))
        }
        'Unknown' {
            $outcome.State = 'TaskUnknown'
            # The count is shown only when items are unknown; a bad Status or exit code alone has no count.
            if ($unknownCount -gt 0) {
                $outcome.Headline = Get-W360Text -Key 'Verify.TaskUnknown.Headline' -Arguments @($unknownCount)
                $outcome.Detail = & $joinDetail (Get-W360Text -Key 'Verify.TaskUnknown.Detail') -WarningsOnly
            }
            else {
                $outcome.Headline = Get-W360Text -Key 'Verify.TaskUnknown.HeadlineNoCount'
                $outcome.Detail = & $joinDetail (Get-W360Text -Key 'Verify.TaskUnknown.DetailNoCount') -WarningsOnly
            }
            $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.RestartAndRetry' -Arguments @($verifyTaskButton, $helpButton))
        }
        default {
            if ($newCount -gt 0) {
                $outcome.State = 'TaskCompletedWithNew'
                $outcome.Headline = Get-W360Text -Key 'Verify.TaskCompletedWithNew.Headline' -Arguments @($newCount)
                $outcome.Detail = & $joinDetail (Get-W360Text -Key 'Verify.TaskCompletedWithNew.Detail')
                $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.RescanDecide' -Arguments @($rescanButton))
            }
            else {
                $outcome.State = 'TaskCompleted'
                if ($coverageComplete -eq $false) {
                    $outcome.Headline = Get-W360Text -Key 'Verify.TaskCompletedIncomplete.Headline'
                    $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.IncompleteRetry')
                }
                elseif ($preservedAttentionCount -gt 0) {
                    $outcome.Headline = Get-W360Text -Key 'Verify.TaskCompletedKeptAttention.Headline'
                    $outcome.NextSteps = @()
                }
                else {
                    $outcome.Headline = Get-W360Text -Key 'Verify.TaskCompleted.Headline'
                    $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.Done')
                }
                $outcome.Detail = & $joinDetail (Get-W360Text -Key 'Verify.TaskCompleted.Detail' -Arguments @($cleared.Count))
            }
        }
    }
    # Other result states already lead to a fresh check; keep their next step focused and all anomalies in Detail.
    if ($outcome.State -eq 'TaskCompleted' -and $coverageComplete -ne $false) {
        if ($outcome.PreservedChangedCount -gt 0 -or $outcome.PreservedUnknownCount -gt 0) {
            $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.KeptUnconfirmed' -Arguments @($rescanButton, $helpButton))
        }
        elseif ($outcome.PreservedGoneCount -gt 0) {
            $outcome.NextSteps = @(Get-W360Text -Key 'Verify.Next.KeptGone')
        }
    }
    return $outcome
}

function ConvertTo-W360TargetRecord {
    param([AllowNull()][object]$Finding)

    return [pscustomobject]@{
        SelectionId         = Get-W360FindingSelectionId -Finding $Finding
        Kind                = Get-W360StringProperty -Object $Finding -Name 'Kind'
        Name                = Get-W360StringProperty -Object $Finding -Name 'Name'
        Target              = Get-W360StringProperty -Object $Finding -Name 'Target'
        ValueName           = Get-W360StringProperty -Object $Finding -Name 'ValueName'
        RemovalType         = Get-W360StringProperty -Object $Finding -Name 'RemovalType'
        IdentityFingerprint = Get-W360StringProperty -Object $Finding -Name 'IdentityFingerprint'
        ProductKey          = Get-W360ProductKey -ProductKey (Get-W360StringProperty -Object $Finding -Name 'ProductKey')
    }
}

function Write-W360NewTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [bool]$ByteOrderMark = $false
    )

    $encoding = New-Object System.Text.UTF8Encoding($ByteOrderMark)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = New-Object IO.StreamWriter($stream, $encoding)
        try { $writer.Write($Text) }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-W360TaskRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ScanReportPath,
        [Parameter(Mandatory = $true)][string]$ScanReportHash,
        [Parameter(Mandatory = $true)][string]$RemoveReportPath,
        [AllowNull()][AllowEmptyCollection()][object[]]$SelectedFindings = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$PreservedFindings = @()
    )

    if ($ScanReportHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'ScanReportHash must be a SHA-256 hex string.' }
    foreach ($value in @($ScanReportPath, $RemoveReportPath)) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n]') { throw 'Task record report paths must be single-line paths.' }
    }
    $path = New-W360ReportPath -Directory $Directory -Kind 'task'
    $record = [pscustomobject]@{
        RecordType        = $script:W360TaskRecordType
        TaskFormatVersion = $script:W360TaskFormatVersion
        ToolVersion       = $script:W360ToolVersion
        CreatedAt         = (Get-Date).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        ScanReport        = [pscustomobject]@{
            Path   = [IO.Path]::GetFullPath($ScanReportPath)
            Sha256 = $ScanReportHash.ToUpperInvariant()
        }
        RemoveReportPath  = [IO.Path]::GetFullPath($RemoveReportPath)
        SelectedTargets   = @(@(Get-W360Items -Value $SelectedFindings) | ForEach-Object { ConvertTo-W360TargetRecord -Finding $_ })
        PreservedTargets  = @(@(Get-W360Items -Value $PreservedFindings) | ForEach-Object { ConvertTo-W360TargetRecord -Finding $_ })
        Notice            = $script:W360TaskNotice
    }
    $json = $record | ConvertTo-Json -Depth 8
    Write-W360NewTextFile -Path $path -Text $json -ByteOrderMark $false
    return $path
}

function ConvertTo-W360DateTimeOffset {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Find-W360LatestVerifiableTask {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [AllowNull()][object]$LastBootTime
    )

    # A newer cleanup attempt that never produced a valid Remove report (for example a declined UAC
    # prompt) must not hide an earlier cleanup that still needs its read-only check after a restart.
    $candidates = @(Get-W360TaskCandidates -Directory $Directory)
    $newerUnusable = 0
    foreach ($candidate in $candidates) {
        $state = Get-W360TaskState -TaskInfo $candidate -LastBootTime $LastBootTime
        if ([bool]$state.RemoveReportValid) {
            return [pscustomobject]@{ TaskState = $state; NewerUnusableCount = $newerUnusable }
        }
        $newerUnusable++
    }
    return $null
}

function Get-W360TaskCandidates {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $latest = Find-W360LatestTask -Directory $Directory -All
    if ($null -eq $latest) { return @() }
    return @($latest)
}

function Find-W360LatestTask {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [switch]$All
    )

    try {
        $fullDirectory = [IO.Path]::GetFullPath($Directory)
        if (-not [IO.Directory]::Exists($fullDirectory)) { return $null }
        $directoryInfo = New-Object IO.DirectoryInfo($fullDirectory)
        $files = @($directoryInfo.GetFiles('360-cleanup-task-*.json', [IO.SearchOption]::TopDirectoryOnly) |
            Where-Object { $_.Name -match '^360-cleanup-task-.+\.json$' } |
            Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 200)
    }
    catch { return $null }

    $invalid = 0
    $incompatible = 0
    $best = $null
    $validRecords = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 4194304) {
            $invalid++
            continue
        }
        $record = $null
        try { $record = Read-W360JsonFile -Path $file.FullName }
        catch { $invalid++; continue }
        if ($null -eq $record -or $record -is [System.Array] -or
            (Get-W360StringProperty -Object $record -Name 'RecordType') -cne $script:W360TaskRecordType) {
            $invalid++
            continue
        }
        if ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $record -Name 'TaskFormatVersion')) -ne $script:W360TaskFormatVersion) {
            $incompatible++
            continue
        }
        $created = ConvertTo-W360DateTimeOffset (Get-W360PropertyValue -Object $record -Name 'CreatedAt')
        $scanReport = Get-W360PropertyValue -Object $record -Name 'ScanReport'
        if ($null -eq $created -or $null -eq $scanReport -or
            (Get-W360StringProperty -Object $scanReport -Name 'Sha256') -notmatch '^[0-9A-Fa-f]{64}$' -or
            [string]::IsNullOrWhiteSpace((Get-W360StringProperty -Object $record -Name 'RemoveReportPath'))) {
            $invalid++
            continue
        }
        $candidate = [pscustomobject]@{ Path = $file.FullName; Record = $record; Created = $created }
        [void]$validRecords.Add($candidate)
        if ($null -eq $best -or $created.UtcDateTime -gt $best.Created.UtcDateTime) {
            $best = $candidate
        }
    }
    if ($All) {
        return @($validRecords | Sort-Object -Property @{ Expression = { $_.Created.UtcDateTime }; Descending = $true } | ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path; Record = $_.Record; CreatedAt = $_.Created.LocalDateTime
                InvalidCount = $invalid; IncompatibleCount = $incompatible
            }
        })
    }
    if ($null -eq $best) { return $null }
    return [pscustomobject]@{
        Path              = $best.Path
        Record            = $best.Record
        CreatedAt         = $best.Created.LocalDateTime
        InvalidCount      = $invalid
        IncompatibleCount = $incompatible
    }
}

function Get-W360TaskState {
    param(
        [Parameter(Mandatory = $true)][object]$TaskInfo,
        [AllowNull()][object]$LastBootTime
    )

    $record = Get-W360PropertyValue -Object $TaskInfo -Name 'Record'
    $removePath = Get-W360StringProperty -Object $record -Name 'RemoveReportPath'
    $scanHash = Get-W360StringProperty -Object (Get-W360PropertyValue -Object $record -Name 'ScanReport') -Name 'Sha256'
    $exists = $false
    try { $exists = -not [string]::IsNullOrWhiteSpace($removePath) -and [IO.File]::Exists($removePath) }
    catch { $exists = $false }

    $issue = ''
    $removeTimestamp = $null
    if (-not $exists) { $issue = 'Missing' }
    else {
        try {
            $report = Read-W360JsonFile -Path $removePath
            if ($null -eq $report -or $report -is [System.Array]) { $issue = 'Unreadable' }
            else {
                $removeTimestamp = ConvertTo-W360DateTimeOffset (Get-W360PropertyValue -Object $report -Name 'Timestamp')
                if ((Get-W360StringProperty -Object $report -Name 'Mode') -cne 'Remove') { $issue = 'NotRemoveReport' }
                elseif ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $report -Name 'SchemaVersion')) -ne 2) { $issue = 'Incompatible' }
                elseif ($scanHash -notmatch '^[0-9A-Fa-f]{64}$' -or
                    -not (Get-W360StringProperty -Object $report -Name 'ApprovedReportHash').Equals($scanHash, [StringComparison]::OrdinalIgnoreCase)) {
                    $issue = 'HashMismatch'
                }
            }
        }
        catch { $issue = 'Unreadable' }
        if ($null -eq $removeTimestamp) {
            try { $removeTimestamp = [DateTimeOffset](New-Object IO.FileInfo($removePath)).LastWriteTime }
            catch { $removeTimestamp = $null }
        }
    }

    $restarted = $null
    $boot = ConvertTo-W360DateTimeOffset $LastBootTime
    if ($null -ne $boot -and $null -ne $removeTimestamp) {
        $restarted = [bool]($boot.UtcDateTime -gt $removeTimestamp.UtcDateTime)
    }

    return [pscustomobject]@{
        TaskInfo             = $TaskInfo
        RemoveReportExists   = [bool]$exists
        RemoveReportValid    = ($exists -and -not $issue)
        RemoveReportIssue    = $issue
        RemoveTimestamp      = $(if ($null -ne $removeTimestamp) { $removeTimestamp.LocalDateTime } else { $null })
        RestartedSinceRemove = $restarted
        SelectedCount        = @(Get-W360ArrayProperty -Object $record -Name 'SelectedTargets').Count
        PreservedCount       = @(Get-W360ArrayProperty -Object $record -Name 'PreservedTargets').Count
    }
}

function Get-W360LastBootTime {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop -Verbose:$false
        $boot = $os.LastBootUpTime
        if ($boot -is [DateTime]) { return $boot }
    }
    catch {}
    return $null
}

function Get-W360SystemInfo {
    $caption = ''
    $version = ''
    $build = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop -Verbose:$false
        $caption = [string]$os.Caption
        $version = [string]$os.Version
        $build = [string]$os.BuildNumber
    }
    catch {}
    try {
        if ([string]::IsNullOrWhiteSpace($version)) { $version = [Environment]::OSVersion.Version.ToString() }
        if ([string]::IsNullOrWhiteSpace($build)) { $build = [string][Environment]::OSVersion.Version.Build }
    }
    catch {}
    $psVersion = ''
    try { $psVersion = $PSVersionTable.PSVersion.ToString() }
    catch { $psVersion = '' }
    $culture = ''
    try { $culture = [Globalization.CultureInfo]::CurrentUICulture.Name }
    catch { $culture = '' }
    $is64 = $false
    try { $is64 = [Environment]::Is64BitOperatingSystem }
    catch { $is64 = $false }
    return [pscustomobject]@{
        OsCaption         = $caption.Trim()
        OsVersion         = $version
        OsBuild           = $build
        PowerShellVersion = $psVersion
        UiCulture         = $culture
        Is64BitOs         = [bool]$is64
    }
}

function New-W360RedactionContext {
    param(
        [AllowNull()][AllowEmptyString()][string]$UserName,
        [AllowNull()][AllowEmptyString()][string]$UserDomain,
        [AllowNull()][AllowEmptyString()][string]$ComputerName,
        [AllowNull()][AllowEmptyString()][string]$UserSid,
        [AllowNull()][object]$PathTokens
    )

    if (-not $PSBoundParameters.ContainsKey('UserName')) {
        try { $UserName = [Environment]::UserName } catch { $UserName = '' }
    }
    if (-not $PSBoundParameters.ContainsKey('UserDomain')) {
        try { $UserDomain = [Environment]::UserDomainName } catch { $UserDomain = '' }
    }
    if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
        try { $ComputerName = [Environment]::MachineName } catch { $ComputerName = '' }
    }
    if (-not $PSBoundParameters.ContainsKey('UserSid')) {
        try { $UserSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $UserSid = '' }
    }

    $rawTokens = New-Object System.Collections.ArrayList
    if ($PSBoundParameters.ContainsKey('PathTokens')) {
        if ($PathTokens -is [System.Collections.IDictionary]) {
            foreach ($key in @($PathTokens.Keys)) {
                [void]$rawTokens.Add([pscustomobject]@{ Path = [string]$key; Token = [string]$PathTokens[$key] })
            }
        }
        else {
            foreach ($entry in @(Get-W360Items -Value $PathTokens)) {
                [void]$rawTokens.Add([pscustomobject]@{
                    Path  = Get-W360StringProperty -Object $entry -Name 'Path'
                    Token = Get-W360StringProperty -Object $entry -Name 'Token'
                })
            }
        }
    }
    else {
        $folder = {
            param([Environment+SpecialFolder]$Name)
            try { return [Environment]::GetFolderPath($Name) } catch { return '' }
        }
        $temp = ''
        try { $temp = [IO.Path]::GetTempPath() } catch { $temp = '' }
        $candidates = @(
            @((& $folder ([Environment+SpecialFolder]::LocalApplicationData)), '%LOCALAPPDATA%'),
            @((& $folder ([Environment+SpecialFolder]::ApplicationData)), '%APPDATA%'),
            @($temp, '%TEMP%'),
            @($env:TEMP, '%TEMP%'),
            @($env:TMP, '%TEMP%'),
            @($env:OneDrive, '%OneDrive%'),
            @($env:OneDriveConsumer, '%OneDrive%'),
            @($env:OneDriveCommercial, '%OneDrive%'),
            @((& $folder ([Environment+SpecialFolder]::Desktop)), (Get-W360Text -Key 'Redact.Desktop')),
            @((& $folder ([Environment+SpecialFolder]::UserProfile)), '%USERPROFILE%')
        )
        foreach ($candidate in $candidates) {
            [void]$rawTokens.Add([pscustomobject]@{ Path = [string]$candidate[0]; Token = [string]$candidate[1] })
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $tokens = New-Object System.Collections.ArrayList
    foreach ($entry in $rawTokens) {
        $path = ([string]$entry.Path).Trim().TrimEnd('\', '/')
        if ($path.Length -lt 4 -or [string]::IsNullOrWhiteSpace([string]$entry.Token)) { continue }
        if (-not $seen.Add($path)) { continue }
        [void]$tokens.Add([pscustomobject]@{ Path = $path; Token = [string]$entry.Token })
    }

    return [pscustomobject]@{
        UserName     = [string]$UserName
        UserDomain   = [string]$UserDomain
        ComputerName = [string]$ComputerName
        UserSid      = [string]$UserSid
        PathTokens   = @($tokens | Sort-Object -Property @{ Expression = { $_.Path.Length }; Descending = $true })
    }
}

function Test-W360RedactableName {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $trimmed = $Value.Trim()
    if ($trimmed -match '[^\x00-\x7F]') { return $trimmed.Length -ge 2 }
    return $trimmed.Length -ge 3
}

function ConvertTo-W360RedactedText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][object]$Context
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $ignoreCase = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $result = $Text
    $userToken = Get-W360Text -Key 'Redact.UserName'

    # 1. Known folders, longest first, in backslash, slash and JSON-escaped spellings.
    foreach ($entry in @(Get-W360ArrayProperty -Object $Context -Name 'PathTokens')) {
        $path = Get-W360StringProperty -Object $entry -Name 'Path'
        $token = Get-W360StringProperty -Object $entry -Name 'Token'
        if ($path.Length -lt 4 -or [string]::IsNullOrEmpty($token)) { continue }
        $variants = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        [void]$variants.Add($path)
        [void]$variants.Add($path.Replace('\', '/'))
        [void]$variants.Add($path.Replace('\', '\\'))
        foreach ($variant in $variants) {
            $pattern = [regex]::Escape($variant) + '(?![^\\/\s"''<>|,;:)\]}])'
            $result = [regex]::Replace($result, $pattern, $token.Replace('$', '$$'), $ignoreCase)
        }
    }

    # 2. Any user profile folder.
    $result = [regex]::Replace($result,
        '(?<![A-Za-z0-9])([A-Za-z]):(\\\\|\\|/)Users(\\\\|\\|/)(?![<%])(?:(?![A-Za-z]:[\\/])[^\\/\r\n\t"<>|:*?])+',
        ('$1:$2Users$3' + $userToken.Replace('$', '$$')), $ignoreCase)

    # 3. Security identifiers.
    $sidToken = Get-W360Text -Key 'Redact.Sid'
    $userSid = Get-W360StringProperty -Object $Context -Name 'UserSid'
    if ($userSid -match '^S-\d+(?:-\d+)+$') {
        $result = [regex]::Replace($result, [regex]::Escape($userSid) + '(?!\d)', ('S-1-5-21-' + $sidToken).Replace('$', '$$'), $ignoreCase)
    }
    $result = [regex]::Replace($result, '(?<![A-Za-z0-9])S-1-5-21(?:-\d+)+', ('S-1-5-21-' + $sidToken).Replace('$', '$$'), $ignoreCase)
    $result = [regex]::Replace($result, '(?<![A-Za-z0-9])S-1-12-1(?:-\d+)+', ('S-1-12-1-' + $sidToken).Replace('$', '$$'), $ignoreCase)

    # 4. E-mail addresses (before names, so a name inside an address cannot break the match).
    $result = [regex]::Replace($result, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+',
        (Get-W360Text -Key 'Redact.Email').Replace('$', '$$'))

    # 5. Remaining absolute drive paths outside Windows, Program Files and ProgramData.
    $privateToken = Get-W360Text -Key 'Redact.PrivatePath'
    $builder = New-Object System.Text.StringBuilder
    $position = 0
    foreach ($match in [regex]::Matches($result, '(?<![A-Za-z0-9])[A-Za-z]:(?:\\\\|\\|/)(?:(?![A-Za-z]:[\\/]|%[A-Za-z]+%)[^\r\n\t"<>|*?:])*')) {
        [void]$builder.Append($result, $position, $match.Index - $position)
        $value = $match.Value.TrimEnd()
        $normalized = ($value -replace '\\\\', '\') -replace '/', '\'
        $matchEnd = $match.Index + $value.Length
        $next = if ($matchEnd -lt $result.Length) { $result.Substring($matchEnd) } else { '' }
        $keep = $normalized.Length -le 3 -or
            $normalized -match '^[A-Za-z]:\\(?:Windows|Program Files \(x86\)|Program Files|ProgramData)(?:\\|$)' -or
            ($normalized -match '^[A-Za-z]:\\Users\\$' -and $next.StartsWith($userToken, [StringComparison]::Ordinal))
        if ($keep) { [void]$builder.Append($value) }
        else { [void]$builder.Append($privateToken) }
        $position = $matchEnd
    }
    [void]$builder.Append($result, $position, $result.Length - $position)
    $result = $builder.ToString()

    # 6. UNC paths.
    $networkToken = Get-W360Text -Key 'Redact.NetworkPath'
    $builder = New-Object System.Text.StringBuilder
    $position = 0
    foreach ($match in [regex]::Matches($result,
        '(?<![\p{L}\p{N}:%>\\])(?:\\\\\\\\|\\\\|//)(?=[\p{L}\p{N}_.$\-])[^\\/\r\n\t"<>|\s]+(?:(?:\\\\|\\|/)[^\r\n\t"<>|]*)?')) {
        [void]$builder.Append($result, $position, $match.Index - $position)
        $value = $match.Value.TrimEnd()
        [void]$builder.Append($networkToken)
        $position = $match.Index + $value.Length
    }
    [void]$builder.Append($result, $position, $result.Length - $position)
    $result = $builder.ToString()

    # 7. Computer, user and domain names as whole tokens.
    foreach ($pair in @(
        @((Get-W360StringProperty -Object $Context -Name 'ComputerName'), (Get-W360Text -Key 'Redact.ComputerName')),
        @((Get-W360StringProperty -Object $Context -Name 'UserName'), $userToken),
        @((Get-W360StringProperty -Object $Context -Name 'UserDomain'), (Get-W360Text -Key 'Redact.Domain'))
    )) {
        $name = [string]$pair[0]
        if (-not (Test-W360RedactableName -Value $name)) { continue }
        $pattern = '(?<![A-Za-z0-9_\-])' + [regex]::Escape($name.Trim()) + '(?![A-Za-z0-9_\-])'
        $result = [regex]::Replace($result, $pattern, ([string]$pair[1]).Replace('$', '$$'), $ignoreCase)
    }
    return $result
}

function ConvertTo-W360UnwrappedErrorLines {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    # Redirected PowerShell error output is hard-wrapped at the host width (usually 120 columns), which can
    # split a private path across lines and defeat redaction. Rejoin full-width lines and drop the
    # CategoryInfo/FullyQualifiedErrorId records, which only repeat the message.
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $raw = @($Text -split "`r?`n")
    $joined = New-Object System.Collections.Generic.List[string]
    $buffer = ''
    foreach ($line in $raw) {
        $buffer += $line
        if ($line.Length -ge 119) { continue }
        $joined.Add($buffer)
        $buffer = ''
    }
    if ($buffer.Length -gt 0) { $joined.Add($buffer) }

    $result = New-Object System.Collections.Generic.List[string]
    $skippingRecord = $false
    foreach ($line in $joined) {
        if ($line -match '^\s*\+\s*(CategoryInfo|FullyQualifiedErrorId)\s*:') { $skippingRecord = $true; continue }
        if ($skippingRecord -and $line -match '^\s{2,}\S' -and $line -notmatch '^\s*\+\s') { continue }
        $skippingRecord = $false
        $result.Add($line)
    }
    return $result.ToArray()
}

function Add-W360HelpFindingLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [AllowNull()][AllowEmptyCollection()][object[]]$Findings,
        [int]$Limit = 40,
        # The effectively deletable set of the check, so each line says what the window said.
        [AllowNull()][object]$Effective
    )

    $items = @(Get-W360Items -Value $Findings)
    $shown = 0
    foreach ($finding in $items) {
        if ($shown -ge $Limit) { break }
        $status = Get-W360FindingStatus -Finding $finding -Effective $Effective
        $Lines.Add(('- [{0}] {1} · {2} · {3}' -f $status.Text, (Get-W360FindingKindText -Finding $finding),
            (Get-W360FindingDisplayName -Finding $finding), (Get-W360StringProperty -Object $finding -Name 'Target')))
        $shown++
    }
    if ($items.Count -gt $shown) { $Lines.Add((Get-W360Text -Key 'Common.MoreItems' -Arguments @($items.Count - $shown))) }
}

function New-W360HelpSummary {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Remove', 'Verify', 'Error')][string]$Stage,
        [AllowNull()][object]$Outcome,
        [AllowNull()][AllowEmptyString()][string]$ErrorText,
        [AllowNull()][AllowEmptyString()][string]$ReportPath,
        [AllowNull()][object]$Context
    )

    if ($null -eq $Context) { $Context = New-W360RedactionContext }
    $system = Get-W360SystemInfo
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-W360Text -Key 'Help.Title'))
    foreach ($key in @('Help.Disclaimer.Redacted', 'Help.Disclaimer.NotApproval', 'Help.Disclaimer.ReportKept', 'Help.Disclaimer.NoUpload')) {
        $lines.Add('* ' + (Get-W360Text -Key $key))
    }
    $lines.Add('')
    $lines.Add((Get-W360Text -Key 'Help.ToolVersion' -Arguments @($script:W360ToolVersion)))
    $bitness = if ($system.Is64BitOs) { Get-W360Text -Key 'Help.Bitness64' } else { Get-W360Text -Key 'Help.Bitness32' }
    $lines.Add((Get-W360Text -Key 'Help.Windows' -Arguments @($system.OsCaption, $system.OsVersion, $system.OsBuild, $bitness)))
    $lines.Add((Get-W360Text -Key 'Help.PowerShell' -Arguments @($system.PowerShellVersion)))
    $lines.Add((Get-W360Text -Key 'Help.UiCulture' -Arguments @($system.UiCulture)))
    $lines.Add((Get-W360Text -Key 'Help.Stage' -Arguments @(Get-W360Text -Key ('Help.Stage.' + $Stage))))

    if ($null -ne $Outcome) {
        $lines.Add((Get-W360Text -Key 'Help.Outcome' -Arguments @(
            (Get-W360StringProperty -Object $Outcome -Name 'State'), (Get-W360StringProperty -Object $Outcome -Name 'Headline'))))
        $detail = Get-W360StringProperty -Object $Outcome -Name 'Detail'
        if (-not [string]::IsNullOrWhiteSpace($detail)) { $lines.Add((Get-W360Text -Key 'Help.OutcomeDetail' -Arguments @($detail))) }
    }
    else {
        $lines.Add((Get-W360Text -Key 'Help.NoOutcome'))
    }
    $reportName = ''
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        try { $reportName = [IO.Path]::GetFileName($ReportPath.Trim()) } catch { $reportName = '' }
    }
    if ([string]::IsNullOrWhiteSpace($reportName)) { $reportName = Get-W360Text -Key 'Common.None' }
    $lines.Add((Get-W360Text -Key 'Help.ReportFile' -Arguments @($reportName)))

    $coverageIssues = @(Get-W360ArrayProperty -Object $Outcome -Name 'CoverageIssues')
    if ($coverageIssues.Count -eq 0) {
        $coverageIssues = @(Get-W360CoverageIssueList -Coverage (Get-W360PropertyValue -Object $Outcome -Name 'Coverage'))
    }
    if ($coverageIssues.Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-W360Text -Key 'Help.CoverageIssues'))
        foreach ($issue in ($coverageIssues | Select-Object -First 40)) {
            $issueParts = @(@((Get-W360StringProperty -Object $issue -Name 'Text'), (Get-W360StringProperty -Object $issue -Name 'Target'),
                (Get-W360StringProperty -Object $issue -Name 'Detail')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Add('- ' + ($issueParts -join ' · '))
        }
    }

    if ($Stage -eq 'Scan' -and $null -ne $Outcome) {
        $findings = @(Get-W360ArrayProperty -Object $Outcome -Name 'Findings')
        # Count with the effectively deletable set, so the numbers match the window and the item lines below.
        $effective = Get-W360OutcomeEffectiveDeletable -Outcome $Outcome
        $deletable = @($findings | Where-Object { Test-W360FindingDeletable -Finding $_ -Effective $effective }).Count
        $lines.Add('')
        $lines.Add((Get-W360Text -Key 'Help.FindingCounts' -Arguments @($findings.Count, $deletable, ($findings.Count - $deletable))))
        Add-W360HelpFindingLines -Lines $lines -Findings $findings -Effective $effective
    }
    elseif ($Stage -eq 'Remove' -and $null -ne $Outcome) {
        $stats = Get-W360PropertyValue -Object $Outcome -Name 'Stats'
        if ($null -ne $stats) {
            $lines.Add('')
            $lines.Add((Get-W360Text -Key 'Help.RemoveStats' -Arguments @(
                (Get-W360StringProperty $stats 'Selected'), (Get-W360StringProperty $stats 'Preserved'),
                (Get-W360StringProperty $stats 'FilesRemoved'), (Get-W360StringProperty $stats 'DirectoriesRemoved'),
                (Get-W360StringProperty $stats 'FailedActions'), (Get-W360StringProperty $stats 'SkippedActions'),
                (Get-W360StringProperty $stats 'PendingActions'))))
        }
        $problems = @(Get-W360ArrayProperty -Object $Outcome -Name 'Problems')
        $lines.Add((Get-W360Text -Key 'Help.Problems' -Arguments @($problems.Count)))
        $shown = 0
        foreach ($problem in $problems) {
            if ($shown -ge 40) { break }
            $lines.Add(('- {0} · {1} · {2} · {3}' -f (Get-W360StringProperty $problem 'ActionText'),
                (Get-W360StringProperty $problem 'ResultText'), (Get-W360StringProperty $problem 'ReasonText'),
                (Get-W360StringProperty $problem 'Target')))
            $shown++
        }
        if ($problems.Count -gt $shown) { $lines.Add((Get-W360Text -Key 'Common.MoreItems' -Arguments @($problems.Count - $shown))) }
        $removeReport = Get-W360PropertyValue -Object $Outcome -Name 'Report'
        $remaining = @(Get-W360ArrayProperty -Object $removeReport -Name 'Findings')
        if ($remaining.Count -gt 0) {
            $rescanComplete = ConvertTo-W360Bool (Get-W360PropertyValue -Object (Get-W360PropertyValue -Object $removeReport -Name 'Summary') -Name 'ImmediateRescanComplete')
            $findingsKey = if ($rescanComplete) { 'Help.RemainingFindings' } else { 'Help.SnapshotFindings' }
            $lines.Add((Get-W360Text -Key $findingsKey -Arguments @($remaining.Count)))
            # Labelled with the effectively deletable set of what is left, as a new check would show it in the window.
            Add-W360HelpFindingLines -Lines $lines -Findings $remaining -Effective (Get-W360EffectiveDeletableIds -Findings $remaining)
        }
    }
    elseif ($Stage -eq 'Verify' -and $null -ne $Outcome) {
        $sections = Get-W360PropertyValue -Object $Outcome -Name 'Sections'
        $cleared = @(Get-W360ArrayProperty -Object $Outcome -Name 'Cleared')
        $sectionKeys = @('SelectedRemaining', 'PreservedGone', 'Preserved', 'NewOrChanged', 'Unknown', 'CurrentIdentified', 'CurrentKept')
        $sectionItems = @{}
        foreach ($key in $sectionKeys) { $sectionItems[$key] = @(Get-W360ArrayProperty -Object $sections -Name $key) }
        $lines.Add('')
        $lines.Add((Get-W360Text -Key 'Help.VerifySections' -Arguments @($cleared.Count,
            $sectionItems['SelectedRemaining'].Count, $sectionItems['Preserved'].Count,
            $sectionItems['NewOrChanged'].Count, $sectionItems['Unknown'].Count, $sectionItems['PreservedGone'].Count)))
        $shown = 0
        $total = $cleared.Count
        foreach ($key in $sectionKeys) { $total += $sectionItems[$key].Count }
        $sectionItems['Cleared'] = $cleared
        foreach ($key in @('Cleared') + $sectionKeys) {
            $title = Get-W360Text -Key ('Verify.Section.' + $key)
            foreach ($item in @($sectionItems[$key])) {
                if ($shown -ge 40) { break }
                $lines.Add(('- [{0}] {1} · {2} · {3} · {4}' -f $title, (Get-W360StringProperty $item 'StateText'),
                    (Get-W360StringProperty $item 'KindText'), (Get-W360StringProperty $item 'DisplayName'),
                    (Get-W360StringProperty $item 'Target')))
                $shown++
            }
        }
        if ($total -gt $shown) { $lines.Add((Get-W360Text -Key 'Common.MoreItems' -Arguments @($total - $shown))) }
    }

    $errorSource = $ErrorText
    if ([string]::IsNullOrWhiteSpace($errorSource)) { $errorSource = Get-W360StringProperty -Object $Outcome -Name 'ErrorText' }
    if (-not [string]::IsNullOrWhiteSpace($errorSource)) {
        # ErrorText is already capped (stderr first, then a short stdout tail); re-tailing it would drop the real error.
        $errorLines = @(ConvertTo-W360UnwrappedErrorLines -Text $errorSource | Select-Object -First 80)
        if ($errorLines.Count -gt 0) {
            $lines.Add('')
            $lines.Add((Get-W360Text -Key 'Help.ErrorText'))
            foreach ($errorLine in $errorLines) { $lines.Add($errorLine) }
        }
    }

    $text = $lines.ToArray() -join "`r`n"
    $text = ConvertTo-W360RedactedText -Text $text -Context $Context
    # Selection IDs, identity fingerprints and run IDs must never leave the PC in a help summary.
    $text = [regex]::Replace($text, '(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{64}|[0-9A-Fa-f]{32})(?![0-9A-Fa-f])',
        (Get-W360Text -Key 'Redact.Identifier').Replace('$', '$$'))
    return $text
}

function Save-W360HelpSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = New-W360ReportPath -Directory $Directory -Kind 'help'
    $normalized = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    Write-W360NewTextFile -Path $path -Text $normalized -ByteOrderMark $true
    return $path
}

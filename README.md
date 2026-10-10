# Todoist Widget

Todoist Widget 是一个基于 Todoist 官方 API 的第三方独立 Windows 任务应用。Todoist 提供任务数据和同步服务，应用提供每日列表、完整月历、任务添加与完成、悬浮置顶、实时时钟，以及自定义颜色、壁纸和透明背景。

应用可直接通过桌面快捷方式启动。连接 Todoist 账号后，无需打开 Todoist 桌面客户端，也能读取和同步任务；跟随 Todoist 启动是可选功能。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1 与系统自带 WPF。
- 一个 Todoist 账号与网络连接。
- 如需启动联动，安装 Todoist Windows 桌面客户端；联动不检测浏览器中的 Todoist 网页。

不需要安装 Python、Node.js 或其他运行环境。

## 下载和连接

1. 从本仓库选择 **Code → Download ZIP**，解压到固定文件夹。
2. 双击 **启动小组件.cmd**。
3. 在 Todoist 打开 **设置 → 关联应用 → 开发者**，找到并复制 API Token。
4. 点击应用中的 **⚙**，在本机粘贴 Token，选择“保存并连接”。

双击 **创建桌面快捷方式.cmd**，会在桌面创建名为 **Todoist Widget** 的快捷方式；以后可直接双击它打开应用。本机已安装 Todoist 时沿用其图标。请保留项目文件夹；移动后重新创建快捷方式。

密钥使用 Windows DPAPI 当前用户加密，保存在 `%LOCALAPPDATA%\TodoistDesktopWidget\token.dat`。它不会写入项目目录，也无需发送给别人。源码和打包文件不包含账号密钥或个人任务。

## 使用

- 深青色界面，拖动标题移动窗口，右下角调整大小。
- 图钉切换窗口置顶，箭头切换日期，点击日期返回今天。
- 显示当前日期的未完成任务，每分钟刷新。
- 勾选后立即变色并显示删除线，后台同步成功后淡出收起；同步失败会恢复任务。循环任务由 Todoist 推进到下一次日期。
- 输入任务内容并回车，添加到所选日期。
- Token 使用 Windows DPAPI 当前用户加密，保存在 `%LOCALAPPDATA%\TodoistDesktopWidget\token.dat`。

## 顶部时钟

顶部的独立时钟栏以较大的字体显示当前本地时间，包含小时、分钟和秒，运行时持续更新。默认使用 24 小时制；在 **⚙ 设置 → 时钟** 中可切换为 12 小时制，显示“上午”或“下午”。切换后立即生效并保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\clock.json`，下次打开继续使用。

## 列表与月历切换

点击日期旁的 **月历**，展开完整月份的周一至周日网格。每天显示任务数量和最多三项任务摘要，更多任务通过“另有 N 项”提示；窗口缩小时会自动减少摘要行，悬停可查看完整任务标题。色条按 Todoist 优先级区分，普通任务使用自定义强调色。

月历中的左右箭头切换月份，点击月份标题返回本月。点击某一天，回到该日列表，可继续添加任务或勾选完成；点击 **列表** 切回当前所选日期的列表。列表中的箭头仍用于切换前后一天。

两种视图在本次运行中分别保留调整后的窗口大小。月历沿用当前颜色、壁纸、透明度和置顶状态；切换直接使用已同步的任务，后台仍每分钟刷新。

月历显示有日期的未完成任务。循环任务按 Todoist 当前到期日期显示，完成后推进到下一次。

## 自定义颜色

点击应用顶部的 **◐** 打开颜色设置。可以选择深青色、石墨黑、浅色、暖色预设，也可以分别选择背景、文字和强调色；支持系统颜色选择器以及 `#RRGGBB` / `#RGB` 色号输入。

修改时会实时预览，点击“保存”后保留颜色，取消或关闭设置会恢复原配色。“恢复默认”用于预览初始配色，保存后生效。按钮、输入框、分隔线和勾选效果会一起适配。

颜色只保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\theme.json`，不会随 GitHub 上传。

## 壁纸与透明背景

点击顶部 **◐** 打开外观设置。在“背景类型”中选择壁纸，再点击“选择图片”，可使用本机 JPG、PNG 或 BMP 图片。图片自动按比例铺满窗口，圆角保持不变；壁纸遮罩使用当前背景颜色，可调节深浅以保持文字清晰。

“背景不透明度”适用于纯色和壁纸：100% 为不透明，0% 为完全透明。也可直接点击“设为完全透明背景”。此设置仅影响背景，任务文字和操作保持清晰。修改会实时预览，保存后继续使用，取消会恢复原外观。

透明时仍可拖动顶部标题或空白区域移动窗口，顶部拖动区域保留极低透明度以接收鼠标，按钮可正常点击。

背景透明度不会降低控件的可见度：透明或壁纸模式下，复选框、输入框和按钮保留清晰底色与较亮边框。

默认保持纯色。壁纸路径和背景设置只保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\background.json`，不会上传到 GitHub，也不会复制或修改所选图片。请保留原图片；图片被移动或删除时，窗口自动退回纯色背景。

## 可选：跟随 Todoist 打开

点击应用中的 **⚙ 设置**，在“启动联动”中打开 **打开 Todoist 时自动启动 Todoist Widget**。切换会立即保存并生效，登录 Windows 后继续沿用；设置页会显示当前是否开启。

之后继续使用原来的 Todoist 图标，本应用会在 Todoist 主窗口稳定显示约一秒后跟随打开。已经打开的应用不会重复打开；手动关闭应用后，同一次 Todoist 使用期间不会反复弹出。从托盘关闭并重新打开 Todoist 窗口也会触发联动。

关闭 Todoist、后台辅助进程启动、短暂窗口变化和最小化恢复不会触发联动。主窗口持续隐藏或关闭约两秒后，下一次打开才会重新触发。

联动负责跟随打开应用。关闭 Todoist 后，本应用仍会留在桌面，通过 API 独立显示和同步任务，也能勾选完成；需要退出本应用时，点击右上角 **×**。

启用后请保留应用文件夹及路径。移动文件夹后，在新位置启动应用，通过设置页重新开启联动。

在同一设置页关闭此开关，即可取消联动。应用会停止后台检测并移除联动启动项，当前窗口保持打开；仍可通过桌面快捷方式独立启动，连接密钥与外观设置继续保留。

`启用联动.cmd` 和 `取消联动.cmd` 保留为手动维护入口，日常使用直接在应用设置中操作。

网络请求在后台执行，不阻塞界面；无网络时保留已有列表并显示错误。

## 记住窗口位置

拖动或调整组件大小后会自动保存；下次打开会恢复上次的位置和列表、月历各自的窗口大小，无需设置。关闭窗口时也会再保存一次。重新打开时，如果显示器已断开或分辨率改变，窗口会自动放到当前屏幕的可见工作区。

位置和大小只保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\window-position.json`，不会上传到 GitHub。

## 当前限制

- 应用采用无系统边框的悬浮窗口，未嵌入桌面背景层。
- 未实现系统托盘、已完成历史、离线操作与提醒弹窗。

## 本地验证

在项目文件夹执行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-animation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-follow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-theme.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-theme-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-background.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-wallpaper-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-calendar.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-calendar-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-follow-settings.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-follow-settings-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-window-position.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-window-position-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-clock-settings.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-clock-ui.ps1
```

测试使用模拟网络响应和进程状态，不读取真实 API Token，也不会调用 Todoist API。动画测试会短暂显示一个测试窗口。

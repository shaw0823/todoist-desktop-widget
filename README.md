# Todoist 桌面小组件

一个连接 Todoist 官方 API 的 Windows 桌面小组件。采用深青色圆角界面，可悬浮置顶、按日期查看任务、勾选完成，并在打开 Todoist 时自动跟随启动。

这是独立桌面工具，需要在本机运行，不是安装到 Todoist 客户端内部的扩展。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1 与系统自带 WPF。
- 一个 Todoist 账号与网络连接。
- 如需启动联动，安装 Todoist Windows 桌面客户端；联动不检测浏览器中的 Todoist 网页。

不需要安装 Python、Node.js 或其他运行环境。

## 下载和连接

1. 从本仓库选择 **Code → Download ZIP**，解压到固定文件夹。
2. 双击 **启动小组件.cmd**。
3. 在 Todoist 打开 **设置 → 集成 → 开发者 → API Token**，复制 Token。
4. 点击小组件的 **⚙**，在本机粘贴 Token，选择“保存并连接”。

密钥使用 Windows DPAPI 当前用户加密，保存在 `%LOCALAPPDATA%\TodoistDesktopWidget\token.dat`。它不会写入项目目录，也无需发送给别人。源码和打包文件不包含账号密钥或个人任务。

## 使用

- 深青色界面，拖动标题移动窗口，右下角调整大小。
- 图钉切换窗口置顶，箭头切换日期，点击日期返回今天。
- 显示当前日期的未完成任务，每分钟刷新。
- 勾选后立即变色并显示删除线，后台同步成功后淡出收起；同步失败会恢复任务。循环任务由 Todoist 推进到下一次日期。
- 输入任务内容并回车，添加到所选日期。
- Token 使用 Windows DPAPI 当前用户加密，保存在 `%LOCALAPPDATA%\TodoistDesktopWidget\token.dat`。

## 自定义颜色

点击组件顶部的 **◐** 打开颜色设置。可以选择深青色、石墨黑、浅色、暖色预设，也可以分别选择背景、文字和强调色；支持系统颜色选择器以及 `#RRGGBB` / `#RGB` 色号输入。

修改时会实时预览，点击“保存”后保留颜色，取消或关闭设置会恢复原配色。“恢复默认”用于预览初始配色，保存后生效。按钮、输入框、分隔线和勾选效果会一起适配。

颜色只保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\theme.json`，不会随 GitHub 上传。

## 壁纸与透明背景

点击顶部 **◐** 打开外观设置。在“背景类型”中选择壁纸，再点击“选择图片”，可使用本机 JPG、PNG 或 BMP 图片。图片自动按比例铺满组件，圆角保持不变；壁纸遮罩使用当前背景颜色，可调节深浅以保持文字清晰。

“背景不透明度”适用于纯色和壁纸：100% 为不透明，0% 为完全透明。也可直接点击“设为完全透明背景”。此设置仅影响背景，任务文字和操作保持清晰。修改会实时预览，保存后继续使用，取消会恢复原外观。

默认保持纯色。壁纸路径和背景设置只保存在本机 `%LOCALAPPDATA%\TodoistDesktopWidget\background.json`，不会上传到 GitHub，也不会复制或修改所选图片。请保留原图片；图片被移动或删除时，组件自动退回纯色背景。

## 跟随 Todoist 打开

双击 **启用联动.cmd**。它会在当前用户的 Windows 登录启动文件夹创建一个快捷方式，并立即开启后台检测。

之后继续使用原来的 Todoist 图标，组件会在主窗口稳定显示约一秒后跟随打开。已经打开的组件不会重复打开；手动关闭组件后，同一次 Todoist 使用期间不会反复弹出。从托盘关闭并重新打开 Todoist 窗口也会触发联动。

关闭 Todoist、后台辅助进程启动、短暂窗口变化和最小化恢复不会触发联动。主窗口持续隐藏或关闭约两秒后，下一次打开才会重新触发。

启用后请保留解压文件夹及路径，否则登录启动快捷方式会失效。移动文件夹后，在新位置重新运行“启用联动.cmd”。

双击“取消联动.cmd”可停止后台检测并移除启动快捷方式。取消联动不影响单独启动组件，也不删除连接密钥。

网络请求在后台执行，不阻塞界面；无网络时保留已有列表并显示错误。

## 当前限制

- 组件是无系统边框的悬浮窗口，未嵌入桌面背景层。
- 未实现系统托盘、已完成历史、离线操作与提醒弹窗。
- 关闭 Todoist 不会自动关闭组件。

## 本地验证

在项目文件夹执行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-animation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-follow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-theme.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-theme-ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-background.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\verify-wallpaper-ui.ps1
```

测试使用模拟网络响应和进程状态，不读取真实 API Token，也不会调用 Todoist API。动画测试会短暂显示一个测试窗口。

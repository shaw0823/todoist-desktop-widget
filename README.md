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

## 跟随 Todoist 打开

双击 **启用联动.cmd**。它会在当前用户的 Windows 登录启动文件夹创建一个快捷方式，并立即开启后台检测。

之后继续使用原来的 Todoist 图标，组件会在约一秒内跟随打开。已经打开的组件不会重复打开；手动关闭组件后，同一次 Todoist 使用期间不会反复弹出。从托盘关闭并重新打开 Todoist 窗口也会触发联动。

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
```

测试使用模拟网络响应和进程状态，不读取真实 API Token，也不会调用 Todoist API。动画测试会短暂显示一个测试窗口。

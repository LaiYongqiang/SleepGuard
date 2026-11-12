# SleepGuard（防休眠助手）

**专为 Vibe Coding 与 AI Agent 时代打造的极致轻量 macOS 原生菜单栏防休眠工具。**

[English](README.md) · [产品需求文档 (PRD)](docs/PRD.md)

> 把有限的电池电量留给真正干活的 **Codex CLI、Claude Code、构建任务与后台服务**，而不是浪费在无人观看的屏幕上。

---

## 界面预览

| 待机状态（浅色） | 运行中倒计时（浅色） | 运行中倒计时（深色） | 偏好设置 |
| :---: | :---: | :---: | :---: |
| <img src="docs/images/preview-idle-light.png" width="210" alt="待机浅色预览" /> | <img src="docs/images/preview-running-light.png" width="210" alt="运行浅色预览" /> | <img src="docs/images/preview-running-dark.png" width="210" alt="运行深色预览" /> | <img src="docs/images/preview-settings-light.png" width="210" alt="偏好设置预览" /> |

---

## 核心特色

- **极致零后台唤醒（0.0% CPU）**：直接基于 macOS 原生 `/usr/bin/caffeinate`。倒计时定时器仅在 Popover 展开可见时运行，收起后彻底销毁，待机与后台运行零唤醒。
- **零孤儿进程守护**：所有 `caffeinate` 子进程均通过 `-w <APP_PID>` 绑定主应用生命周期，无论正常退出还是意外强杀，系统内核自动回收断言。
- **记忆配置 + 一次回车直启**：自动记住上一次模式、锁屏/合盖选项与时长。打开面板按 `Enter` 即可按上次配置启动；运行中按 `Enter` 或 `Esc` 立即收起。
- **两种纯正运行模式**：
  - **后台运行**（`caffeinate -i`，默认）：阻止系统空闲睡眠、允许屏幕熄灭省电。支持记忆开关「启动即锁屏」与可选「合盖继续运行（背包模式）」。
  - **屏幕常亮**（`caffeinate -di`）：保持系统与桌面窗口渲染活跃，适合 **Computer Use 桌面操控**、投屏演示与日志监看。（*跑 Computer Use 时建议手动把屏幕亮度调至最低以兼顾省电*）
- **真正在背包里可用的「合盖模式」**：默认关闭、显式勾选并经系统 Touch ID / 管理员授权执行 `pmset -a disablesleep 1`，配合内核 `kqueue` + `trap` 守护机制，停止、超时或应用崩溃退出时自动恢复 `disablesleep 0`。
- **零轮询低电量安全阈值**：基于 `IOKit.ps` `IOPSNotificationCreateRunLoopSource` 事件回调（默认低于 `10%` 且未充电时自动停止并恢复休眠保护）。

---

## 原生 macOS 交互细节

- **左键菜单栏图标**：展开 / 收起 Popover 卡片
- **右键菜单栏图标**：快速启动上次配置、立即停止、锁定屏幕、开关「登录时自动启动」（`SMAppService`）、打开偏好设置
- **全键盘闭环**：`Enter` 直启 / 收起、`Esc` 返回 / 关闭、`Cmd+,` 偏好设置、`Cmd+Q` 安全退出
- **单实例保护**：重复打开自动唤起已有菜单栏面板，不产生重复图标
- **双语自适应**：自动跟随系统切换简体中文 / English，亦可在设置中手动指定

---

## 从源码构建（macOS 13+）

仅需安装 Xcode Command Line Tools（Swift 5.10+），无需完整 Xcode：

```bash
git clone https://github.com/LaiYongqiang/SleepGuard.git
cd SleepGuard

# 运行单元测试与 caffeinate -w 生命周期测试
swift test

# 构建 SleepGuard.app、ZIP 与 DMG 安装包（输出到 ./dist/）
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

---

## 架构红线

1. 严禁 Popover 不可见时的后台定时器、状态栏每秒重绘或 `ps`/`pmset` 轮询。
2. 严禁静默或无自动恢复兜底地修改系统电源配置。
3. 严禁使用模拟鼠标微动/虚拟按键绕过系统锁屏安全机制。
4. 严禁调用 `killall caffeinate` 误杀其他应用断言。
5. 严禁引入 Electron、WebView 或重型后台常驻服务。

---

## 开源协议

[MIT License](LICENSE) © 2026 LaiYongqiang

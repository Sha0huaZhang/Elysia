# Elysia

Apple Music 缺失的图形界面。

[English](./README.md) · **简体中文**

## 系统要求

- macOS Ventura13 或更高版本
- Apple Music，且已建立资料库（Elysia 只是驱动「音乐」App，本身不播放音频）

## 界面语言

界面提供英文与简体中文两套独立语言包，分别位于 `Elysia/en.lproj` 与
`Elysia/zh-Hans.lproj`。默认跟随系统语言；可在**设置 → 语言**中手动指定，
重启后生效。

## 为什么选择Elysia？

**1.迎来清爽页面。** I.用专辑封面覆盖歌曲卡片左侧、增加识别效率。II.去掉了“广播”“iTunes”等不常用的侧边栏目和“类型”“评分”“播放次数”等状态栏。  
**2.优化界面结构。** I.将“艺人”栏目移至歌曲下方同时变为灰色和更小字体，便于阅读的同时兼顾美观。II.正在播放的歌曲的专辑封面边框变为红色、字体变为加粗的红色字体，同时进度条和音量调节条也为红色，增加辨识度。  
**3.AppleMusic没有的功能。** I.拖动歌曲可以调节顺序。  
  
## 对比图片     
**Elysia：**    
<p align="center">
  <img src="images/compare1.png" alt="compare1" width="80%" style="max-width: 720px;">  
<p align="center">
  <img src="images/compare2.png" alt="compare2" width="80%" style="max-width: 720px;"> 
    
**Apple Music：**  

</p>
<p align="center">
  <img src="images/compare3.png" alt="compare3" width="80%" style="max-width: 720px;">
</p>  
<p align="center">
  <img src="images/compare4.png" alt="compare4" width="80%" style="max-width: 720px;"> 

## 安装

1. 从[官网（elysia.macwave.org/Downloads）](https://elysia.com/downloads)或 [Releases 页面](../../releases) 下载 `Elysia-x.y.z.dmg`。
2. 打开 DMG，把 **Elysia** 拖到 **Applications** 快捷方式上。
3. 从「应用程序」启动 Elysia，macOS 询问时允许它控制**「音乐」**。

### 如果 macOS 拒绝打开

发布的版本已签名但**未公证**（公证需要付费的 Apple 开发者账号），因此
Gatekeeper 会提示「无法验证开发者」。以下任一方法都可以：

- 在「应用程序」中右键（或按住 Control 点击）Elysia，选择**打开**，再确认一次。
  macOS 会记住这个选择。
- 或者清除下载隔离标记：

  ```sh
  xattr -dr com.apple.quarantine /Applications/Elysia.app
  ```

## 演示图片


<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>
<p align="center">
  <img src="images/demo2.png" alt="demo2" width="80%" style="max-width: 720px;">
</p>

## 使用方法
**播放/暂停**： 双击歌曲或点击播放/暂停键  
**调整歌单顺序**： 拖动歌曲到要调整到的两首歌之间并松开
**切换播放模式**： 点击顶部播放模式按钮（无/列表循环/单曲循环)
**调整语言/恢复默认歌曲排序**： 点击左侧边栏的**设置**按钮并在窗口内调整。
## 从源码构建

Xcode 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 依据 `project.yml`
生成，因此 `Elysia.xcodeproj` 是可以随时丢弃的产物：

```sh
xcodegen generate
open Elysia.xcodeproj
```

要在 `dist/` 下生成已签名、兼容 Intel 的通用版（arm64 + x86_64）DMG：

```sh
Scripts/package-dmg.sh
```

脚本会自动使用钥匙串中第一个 `Apple Development` 证书；可通过 `SIGN_IDENTITY`
指定其它证书，或设为 `-` 使用 ad-hoc 签名。脚本**刻意不启用硬化运行时**：启用后
需要额外声明 `com.apple.security.automation.apple-events` 权限才能继续控制「音乐」，
而个人团队本就无法公证，启用它没有收益。

### 查看打包好的镜像

`Scripts/elysiadmgrun` 会挂载镜像并在 Finder 中打开，是检查安装体验最快的方式：

```sh
Scripts/elysiadmgrun              # dmg/ 下最新的镜像
Scripts/elysiadmgrun path.dmg     # 指定镜像
Scripts/elysiadmgrun --eject      # 卸载
```

想把它变成一条命令，做个软链放到 `PATH` 里即可：

```sh
ln -s "$PWD/Scripts/elysiadmgrun" ~/.local/bin/elysiadmgrun
```

App 图标由单张原图通过 `Scripts/generate-appicon.py` 重新生成。

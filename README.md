# Apple Music Bar

一个只驻留在 macOS 菜单栏的 Apple Music 同步歌词应用。没有 Dock 图标，也不会创建常驻窗口。

## 功能

- 读取 Apple Music 当前曲目与播放进度
- 优先显示 LRC 时间轴歌词
- 精确匹配失败时自动尝试简繁体标题和宽松搜索
- 状态栏逐句同步，长歌词自动滚动
- 菜单顶部提供封面、曲目信息、播放/暂停与下一首控制
- 支持跟随系统、简体中文、English 和繁體中文界面
- 未匹配到同步歌词时，按歌曲时长估算普通歌词进度
- 点击歌词可进行上一首、播放/暂停、下一首和重新匹配
- Apple Music 未启动时保持安静驻留

## 构建与运行

需要 macOS 13 或更高版本，以及 Xcode / Xcode Command Line Tools。

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/AppleMusicBar.app
```

第一次读取播放信息时，macOS 会询问是否允许 Apple Music Bar 控制“音乐”。请选择“允许”。如果曾经拒绝，可前往：

> 系统设置 → 隐私与安全性 → 自动化 → Apple Music Bar → 音乐

运行测试：

```bash
swift test
```

可选的 LRCLIB 在线匹配测试：

```bash
APPLE_MUSIC_BAR_INTEGRATION_TESTS=1 swift test --filter LyricsRepositoryIntegrationTests
```

## 发布

推送 `v*` tag 后，[Release workflow](.github/workflows/release.yml) 会在 GitHub 的 macOS runner 上运行测试、构建 arm64+x86_64 通用应用、生成 SHA-256 校验文件并创建 GitHub Release。tag 必须与 `Resources/Info.plist` 中的版本一致。

```bash
git push origin main --tags
```

也可以在 GitHub Actions 页面手动运行工作流并填写已经存在的 tag；这适合补发旧版本。

## 歌词来源与隐私

应用先检查曲目内嵌的时间轴歌词，再请求 [LRCLIB](https://lrclib.net)。在线匹配只会发送歌名、歌手、专辑和曲目时长；不会读取或上传 Apple ID、资料库、播放历史或任何账号令牌。

Apple Music 自带的目录歌词没有公开的桌面端逐行读取接口，因此在线歌曲不一定能直接取得 Apple 官方歌词。LRCLIB 匹配失败时，应用会回退到曲目内嵌歌词；两者都没有时显示歌名与歌手。
